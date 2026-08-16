import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../models/game_entry.dart';
import '../models/move_node.dart';
import '../services/move_evaluator.dart';

/// Persistence layer for games and their move trees.
///
/// Schema (v5):
///   * `games`        — per-game metadata. No PGN text; move data lives in
///                      `move_nodes`. A cached `lastFen` lets the list screen
///                      render a thumbnail without loading the full tree.
///   * `move_nodes`   — one row per [MoveNode], linked back to a parent row
///                      via `parentId` (NULL for the root). `orderIndex`
///                      gives sibling ordering — index 0 is the mainline.
class DatabaseService {
  static Database? _database;
  static const String _gamesTable = 'games';
  static const String _nodesTable = 'move_nodes';

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    // The web database factory has no real filesystem, so getDatabasesPath()
    // isn't implemented there — just use the bare db name (it's stored in
    // IndexedDB under that name).
    final path = kIsWeb
        ? 'centipawn.db'
        : join(await getDatabasesPath(), 'centipawn.db');

    return await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Per the chosen migration strategy ("reseed only"), older schemas
        // are dropped wholesale and the caller re-seeds the famous-games
        // list on next launch.
        await db.execute('DROP TABLE IF EXISTS $_gamesTable');
        await db.execute('DROP TABLE IF EXISTS $_nodesTable');
        await _createSchema(db);
      },
    );
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE $_gamesTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        white TEXT NOT NULL,
        black TEXT NOT NULL,
        event TEXT NOT NULL,
        result TEXT NOT NULL,
        year TEXT NOT NULL,
        isReviewed INTEGER NOT NULL DEFAULT 0,
        tags TEXT NOT NULL DEFAULT '',
        timeControl TEXT NOT NULL DEFAULT '',
        date TEXT NOT NULL DEFAULT '',
        site TEXT NOT NULL DEFAULT '',
        round TEXT NOT NULL DEFAULT '',
        whiteElo TEXT NOT NULL DEFAULT '',
        blackElo TEXT NOT NULL DEFAULT '',
        openingCode TEXT NOT NULL DEFAULT '',
        whiteAccuracy REAL,
        blackAccuracy REAL,
        lastFen TEXT NOT NULL DEFAULT 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'
      )
    ''');
    await db.execute('''
      CREATE TABLE $_nodesTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        gameId INTEGER NOT NULL,
        parentId INTEGER,
        orderIndex INTEGER NOT NULL,
        fen TEXT NOT NULL,
        san TEXT NOT NULL DEFAULT '',
        uci TEXT,
        evaluation REAL,
        mate INTEGER,
        quality TEXT,
        bestMoveUci TEXT,
        bestMoveEval REAL,
        bestMoveMate INTEGER,
        commentsJson TEXT NOT NULL DEFAULT '[]',
        glyphsJson TEXT NOT NULL DEFAULT '[]',
        FOREIGN KEY (gameId) REFERENCES $_gamesTable(id) ON DELETE CASCADE,
        FOREIGN KEY (parentId) REFERENCES $_nodesTable(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_nodes_game ON $_nodesTable (gameId, parentId, orderIndex)');
  }

  // ---------------------------------------------------------------------------
  // Game CRUD
  // ---------------------------------------------------------------------------

  /// Create a new game row + its move tree atomically.
  /// Returns the row with [GameEntry.id] populated.
  static Future<GameEntry> insertGame(GameEntry game, MoveTree tree) async {
    final db = await database;
    return await db.transaction((txn) async {
      final stamped = game.copyWith(lastFen: _lastFenOf(tree));
      final id = await txn.insert(_gamesTable, stamped.toMap());
      await _writeTreeTx(txn, id, tree);
      return stamped.copyWith(id: id);
    });
  }

  /// Update game metadata only — does not touch the move tree.
  static Future<void> updateGameMetadata(GameEntry game) async {
    final db = await database;
    await db.update(
      _gamesTable,
      game.toMap(),
      where: 'id = ?',
      whereArgs: [game.id],
    );
  }

  /// Rewrites the move tree for [gameId] and refreshes the cached `lastFen`.
  /// All previous rows for the game are deleted in the same transaction.
  static Future<void> saveTree(int gameId, MoveTree tree) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(_nodesTable, where: 'gameId = ?', whereArgs: [gameId]);
      await _writeTreeTx(txn, gameId, tree);
      await txn.update(
        _gamesTable,
        {'lastFen': _lastFenOf(tree)},
        where: 'id = ?',
        whereArgs: [gameId],
      );
    });
  }

  static Future<List<GameEntry>> getAllGames() async {
    final db = await database;
    final maps = await db.query(_gamesTable, orderBy: 'id DESC');
    return maps.map((m) => GameEntry.fromMap(m)).toList();
  }

  static Future<GameEntry?> getGame(int id) async {
    final db = await database;
    final maps = await db.query(
      _gamesTable,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return GameEntry.fromMap(maps.first);
  }

  static Future<void> deleteGame(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(_nodesTable, where: 'gameId = ?', whereArgs: [id]);
      await txn.delete(_gamesTable, where: 'id = ?', whereArgs: [id]);
    });
  }

  // ---------------------------------------------------------------------------
  // Move tree load
  // ---------------------------------------------------------------------------

  /// Reconstruct the move tree for [gameId] from `move_nodes` rows.
  /// Returns an empty tree (root only, standard start position) if the game
  /// has no rows yet.
  static Future<MoveTree> loadMoveTree(int gameId) async {
    final db = await database;
    final rows = await db.query(
      _nodesTable,
      where: 'gameId = ?',
      whereArgs: [gameId],
      orderBy: 'parentId ASC, orderIndex ASC',
    );
    if (rows.isEmpty) {
      return MoveTree(
        initialFen:
            'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
    }

    // Build nodes first, then wire parents/children in a second pass so
    // forward references in the row stream don't matter.
    final nodesById = <int, MoveNode>{};
    int? rootId;
    for (final row in rows) {
      final id = row['id'] as int;
      final node = _nodeFromRow(row);
      nodesById[id] = node;
      if (row['parentId'] == null) rootId = id;
    }
    if (rootId == null) {
      // Defensive — shouldn't happen with well-formed data.
      return MoveTree(
        initialFen:
            'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
    }

    final childrenByParent = <int, List<MapEntry<int, int>>>{};
    for (final row in rows) {
      final pid = row['parentId'] as int?;
      if (pid == null) continue;
      final id = row['id'] as int;
      final order = row['orderIndex'] as int;
      childrenByParent.putIfAbsent(pid, () => []).add(MapEntry(id, order));
    }
    for (final entries in childrenByParent.values) {
      entries.sort((a, b) => a.value.compareTo(b.value));
    }
    void attach(int parentId) {
      final parent = nodesById[parentId]!;
      final kids = childrenByParent[parentId] ?? const [];
      for (final entry in kids) {
        final child = nodesById[entry.key]!;
        parent.addChild(child);
        attach(entry.key);
      }
    }
    attach(rootId);

    return MoveTree.withRoot(nodesById[rootId]!);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static String _lastFenOf(MoveTree tree) => tree.lastMainlineNode.fen;

  /// Write the entire tree under [gameId] inside the active [txn]. Caller
  /// is responsible for clearing existing rows first if needed.
  static Future<void> _writeTreeTx(
      Transaction txn, int gameId, MoveTree tree) async {
    Future<int> writeNode(MoveNode node, int? parentId, int order) async {
      final id = await txn.insert(_nodesTable, _nodeToMap(node, gameId, parentId, order));
      for (int i = 0; i < node.children.length; i++) {
        await writeNode(node.children[i], id, i);
      }
      return id;
    }

    await writeNode(tree.root, null, 0);
  }

  static Map<String, dynamic> _nodeToMap(
      MoveNode node, int gameId, int? parentId, int orderIndex) {
    return {
      'gameId': gameId,
      'parentId': parentId,
      'orderIndex': orderIndex,
      'fen': node.fen,
      'san': node.san,
      'uci': node.uci,
      'evaluation': node.evaluation,
      'mate': node.mate,
      'quality': node.quality?.name,
      'bestMoveUci': node.bestMoveUci,
      'bestMoveEval': node.bestMoveEval,
      'bestMoveMate': node.bestMoveMate,
      'commentsJson': jsonEncode(node.comments),
      'glyphsJson': jsonEncode(node.glyphs),
    };
  }

  static MoveNode _nodeFromRow(Map<String, dynamic> row) {
    final qualityName = row['quality'] as String?;
    final quality = qualityName == null
        ? null
        : MoveQuality.values.firstWhere(
            (q) => q.name == qualityName,
            orElse: () => MoveQuality.good,
          );

    final commentsRaw = row['commentsJson'] as String? ?? '[]';
    final glyphsRaw = row['glyphsJson'] as String? ?? '[]';
    final comments = (jsonDecode(commentsRaw) as List)
        .map((e) => e.toString())
        .toList();
    final glyphs =
        (jsonDecode(glyphsRaw) as List).map((e) => e as int).toList();

    return MoveNode(
      fen: row['fen'] as String,
      san: row['san'] as String? ?? '',
      uci: row['uci'] as String?,
      evaluation: (row['evaluation'] as num?)?.toDouble(),
      mate: row['mate'] as int?,
      quality: quality,
      bestMoveUci: row['bestMoveUci'] as String?,
      bestMoveEval: (row['bestMoveEval'] as num?)?.toDouble(),
      bestMoveMate: row['bestMoveMate'] as int?,
      comments: comments,
      glyphs: glyphs,
    );
  }
}
