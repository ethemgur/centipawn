/// Game-level metadata. The move tree is stored separately in the
/// `move_nodes` table — load it via `DatabaseService.loadMoveTree(id)`.
class GameEntry {
  final int? id;
  final String white;
  final String black;
  final String event;
  final String result;
  final String year;
  final bool isReviewed;
  final List<String> tags;
  final String timeControl;
  final String date;
  final String site;
  final String round;
  final String whiteElo;
  final String blackElo;
  final String openingCode;
  final double? whiteAccuracy;
  final double? blackAccuracy;

  /// Last mainline FEN, cached on the row so the list screen can render a
  /// thumbnail without loading every move node.
  final String lastFen;

  const GameEntry({
    this.id,
    required this.white,
    required this.black,
    required this.event,
    required this.result,
    required this.year,
    this.isReviewed = false,
    this.tags = const [],
    this.timeControl = '',
    this.date = '',
    this.site = '',
    this.round = '',
    this.whiteElo = '',
    this.blackElo = '',
    this.openingCode = '',
    this.whiteAccuracy,
    this.blackAccuracy,
    this.lastFen =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
  });

  String get title {
    final w = white.trim();
    final b = black.trim();
    if (w.isEmpty && b.isEmpty) return 'Untitled Game';
    return '$white vs $black';
  }

  GameEntry copyWith({
    int? id,
    String? white,
    String? black,
    String? event,
    String? result,
    String? year,
    bool? isReviewed,
    List<String>? tags,
    String? timeControl,
    String? date,
    String? site,
    String? round,
    String? whiteElo,
    String? blackElo,
    String? openingCode,
    double? whiteAccuracy,
    double? blackAccuracy,
    String? lastFen,
  }) {
    return GameEntry(
      id: id ?? this.id,
      white: white ?? this.white,
      black: black ?? this.black,
      event: event ?? this.event,
      result: result ?? this.result,
      year: year ?? this.year,
      isReviewed: isReviewed ?? this.isReviewed,
      tags: tags ?? this.tags,
      timeControl: timeControl ?? this.timeControl,
      date: date ?? this.date,
      site: site ?? this.site,
      round: round ?? this.round,
      whiteElo: whiteElo ?? this.whiteElo,
      blackElo: blackElo ?? this.blackElo,
      openingCode: openingCode ?? this.openingCode,
      whiteAccuracy: whiteAccuracy ?? this.whiteAccuracy,
      blackAccuracy: blackAccuracy ?? this.blackAccuracy,
      lastFen: lastFen ?? this.lastFen,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'white': white,
      'black': black,
      'event': event,
      'result': result,
      'year': year,
      'isReviewed': isReviewed ? 1 : 0,
      'tags': tags.join(','),
      'timeControl': timeControl,
      'date': date,
      'site': site,
      'round': round,
      'whiteElo': whiteElo,
      'blackElo': blackElo,
      'openingCode': openingCode,
      'whiteAccuracy': whiteAccuracy,
      'blackAccuracy': blackAccuracy,
      'lastFen': lastFen,
    };
  }

  factory GameEntry.fromMap(Map<String, dynamic> map) {
    return GameEntry(
      id: map['id'] as int?,
      white: map['white'] as String,
      black: map['black'] as String,
      event: map['event'] as String,
      result: map['result'] as String,
      year: map['year'] as String,
      isReviewed: (map['isReviewed'] as int? ?? 0) == 1,
      tags: (map['tags'] as String?)
              ?.split(',')
              .where((t) => t.isNotEmpty)
              .toList() ??
          [],
      timeControl: map['timeControl'] as String? ?? '',
      date: map['date'] as String? ?? '',
      site: map['site'] as String? ?? '',
      round: map['round'] as String? ?? '',
      whiteElo: map['whiteElo'] as String? ?? '',
      blackElo: map['blackElo'] as String? ?? '',
      openingCode: map['openingCode'] as String? ?? '',
      whiteAccuracy: (map['whiteAccuracy'] as num?)?.toDouble(),
      blackAccuracy: (map['blackAccuracy'] as num?)?.toDouble(),
      lastFen: map['lastFen'] as String? ??
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    );
  }
}
