import '../models/move_node.dart';

class _Opening {
  final String eco;
  final String name;
  final List<String> moves;
  const _Opening(this.eco, this.name, this.moves);
}

/// Detects the chess opening from a mainline by longest-prefix match.
class OpeningService {
  static String? detect(List<MoveNode> mainline) {
    if (mainline.isEmpty) return null;
    final sans = mainline.map((n) => n.san).toList();

    String? bestEco;
    String? bestName;
    int bestLength = 0;

    for (final o in _openings) {
      final len = o.moves.length;
      if (len > sans.length) continue;
      bool ok = true;
      for (int i = 0; i < len; i++) {
        if (sans[i] != o.moves[i]) { ok = false; break; }
      }
      if (ok && len > bestLength) {
        bestLength = len;
        bestEco = o.eco;
        bestName = o.name;
      }
    }

    return bestLength > 0 ? '$bestEco: $bestName' : null;
  }

  static const _openings = <_Opening>[
    // A — Flank openings
    _Opening('A00', "King's Fianchetto", ['g3']),
    _Opening('A01', "Nimzo-Larsen Attack", ['b3']),
    _Opening('A02', "Bird's Opening", ['f4']),
    _Opening('A04', "Reti Opening", ['Nf3']),
    _Opening('A05', "Reti: King's Indian Attack", ['Nf3', 'g3']),
    _Opening('A10', "English Opening", ['c4']),
    _Opening('A15', "English: Anglo-Indian", ['c4', 'Nf6']),
    _Opening('A20', "English: King's English", ['c4', 'e5']),
    _Opening('A25', "English: King's English, Reversed Sicilian", ['c4', 'e5', 'Nc3', 'Nc6']),
    _Opening('A30', "English: Symmetrical", ['c4', 'c5']),
    _Opening('A40', "Queen's Pawn", ['d4', 'e6']),
    _Opening('A41', "Queen's Pawn: Modern Defence", ['d4', 'd6']),
    _Opening('A43', "Benoni Defence", ['d4', 'c5']),
    _Opening('A45', "Trompowsky Attack", ['d4', 'Nf6', 'Bg5']),
    _Opening('A46', "Queen's Pawn: Torre Attack", ['d4', 'Nf6', 'Nf3']),
    _Opening('A51', "Budapest Gambit", ['d4', 'Nf6', 'c4', 'e5']),
    _Opening('A57', "Benko Gambit", ['d4', 'Nf6', 'c4', 'c5', 'd5', 'b5']),
    _Opening('A60', "Benoni: Modern", ['d4', 'Nf6', 'c4', 'c5', 'd5', 'e6']),
    _Opening('A80', "Dutch Defence", ['d4', 'f5']),
    _Opening('A84', "Dutch: Staunton Gambit", ['d4', 'f5', 'e4']),

    // B — Semi-open games
    _Opening('B00', "King's Pawn Opening", ['e4']),
    _Opening('B01', "Scandinavian Defence", ['e4', 'd5']),
    _Opening('B02', "Alekhine's Defence", ['e4', 'Nf6']),
    _Opening('B06', "Modern Defence", ['e4', 'g6']),
    _Opening('B07', "Pirc Defence", ['e4', 'd6', 'd4', 'Nf6']),
    _Opening('B09', "Pirc: Austrian Attack", ['e4', 'd6', 'd4', 'Nf6', 'Nc3', 'g6', 'f4']),
    _Opening('B10', "Caro-Kann Defence", ['e4', 'c6']),
    _Opening('B12', "Caro-Kann: Advance", ['e4', 'c6', 'd4', 'd5', 'e5']),
    _Opening('B13', "Caro-Kann: Exchange", ['e4', 'c6', 'd4', 'd5', 'exd5', 'cxd5']),
    _Opening('B14', "Caro-Kann: Panov-Botvinnik", ['e4', 'c6', 'd4', 'd5', 'exd5', 'cxd5', 'c4']),
    _Opening('B17', "Caro-Kann: Steinitz", ['e4', 'c6', 'd4', 'd5', 'Nc3', 'dxe4', 'Nxe4', 'Nd7']),
    _Opening('B20', "Sicilian Defence", ['e4', 'c5']),
    _Opening('B21', "Sicilian: Smith-Morra Gambit", ['e4', 'c5', 'd4', 'cxd4', 'c3']),
    _Opening('B22', "Sicilian: Alapin", ['e4', 'c5', 'c3']),
    _Opening('B23', "Sicilian: Closed", ['e4', 'c5', 'Nc3']),
    _Opening('B27', "Sicilian: Hyper-Accelerated Dragon", ['e4', 'c5', 'Nf3', 'g6']),
    _Opening('B30', "Sicilian: Old Sicilian", ['e4', 'c5', 'Nf3', 'Nc6']),
    _Opening('B32', "Sicilian: Labourdonnais-Loewenthal", ['e4', 'c5', 'Nf3', 'Nc6', 'd4', 'cxd4', 'Nxd4', 'e5']),
    _Opening('B40', "Sicilian Defence", ['e4', 'c5', 'Nf3', 'e6']),
    _Opening('B41', "Sicilian: Kan", ['e4', 'c5', 'Nf3', 'e6', 'd4', 'cxd4', 'Nxd4', 'a6']),
    _Opening('B44', "Sicilian: Taimanov", ['e4', 'c5', 'Nf3', 'e6', 'd4', 'cxd4', 'Nxd4', 'Nc6']),
    _Opening('B45', "Sicilian: Four Knights", ['e4', 'c5', 'Nf3', 'e6', 'd4', 'cxd4', 'Nxd4', 'Nc6', 'Nc3']),
    _Opening('B50', "Sicilian", ['e4', 'c5', 'Nf3', 'd6']),
    _Opening('B54', "Sicilian: Dragon", ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'g6']),
    _Opening('B57', "Sicilian: Sozin", ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'Nc6', 'Bc4']),
    _Opening('B60', "Sicilian: Richter-Rauzer", ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'Nc6', 'Bg5']),
    _Opening('B70', "Sicilian: Dragon", ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'g6']),
    _Opening('B80', "Sicilian: Scheveningen", ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'e6']),
    _Opening('B90', "Sicilian: Najdorf", ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'a6']),
    _Opening('B96', "Sicilian: Najdorf, Poisoned Pawn", ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'a6', 'Bg5', 'e6', 'f4', 'Qb6']),

    // C — Open games
    _Opening('C00', "French Defence", ['e4', 'e6']),
    _Opening('C01', "French: Exchange", ['e4', 'e6', 'd4', 'd5', 'exd5', 'exd5']),
    _Opening('C02', "French: Advance", ['e4', 'e6', 'd4', 'd5', 'e5']),
    _Opening('C03', "French: Tarrasch", ['e4', 'e6', 'd4', 'd5', 'Nd2']),
    _Opening('C10', "French: Rubinstein", ['e4', 'e6', 'd4', 'd5', 'Nc3', 'dxe4']),
    _Opening('C11', "French: Classical", ['e4', 'e6', 'd4', 'd5', 'Nc3', 'Nf6']),
    _Opening('C15', "French: Winawer", ['e4', 'e6', 'd4', 'd5', 'Nc3', 'Bb4']),
    _Opening('C20', "King's Pawn Game", ['e4', 'e5']),
    _Opening('C21', "Danish Gambit", ['e4', 'e5', 'd4', 'exd4', 'c3']),
    _Opening('C23', "Bishop's Opening", ['e4', 'e5', 'Bc4']),
    _Opening('C24', "Bishop's Opening: Berlin Defence", ['e4', 'e5', 'Bc4', 'Nf6']),
    _Opening('C25', "Vienna Game", ['e4', 'e5', 'Nc3']),
    _Opening('C30', "King's Gambit", ['e4', 'e5', 'f4']),
    _Opening('C33', "King's Gambit Accepted", ['e4', 'e5', 'f4', 'exf4']),
    _Opening('C40', "King's Knight Opening", ['e4', 'e5', 'Nf3']),
    _Opening('C41', "Philidor Defence", ['e4', 'e5', 'Nf3', 'd6']),
    _Opening('C42', "Russian Game (Petrov)", ['e4', 'e5', 'Nf3', 'Nf6']),
    _Opening('C44', "Scotch Game", ['e4', 'e5', 'Nf3', 'Nc6', 'd4']),
    _Opening('C45', "Scotch Game", ['e4', 'e5', 'Nf3', 'Nc6', 'd4', 'exd4', 'Nxd4']),
    _Opening('C46', "Three Knights Game", ['e4', 'e5', 'Nf3', 'Nc6', 'Nc3']),
    _Opening('C47', "Four Knights Game", ['e4', 'e5', 'Nf3', 'Nc6', 'Nc3', 'Nf6']),
    _Opening('C50', "Italian Game", ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4']),
    _Opening('C51', "Evans Gambit", ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5', 'b4']),
    _Opening('C53', "Italian: Classical", ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5', 'c3']),
    _Opening('C54', "Italian: Giuoco Piano", ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5', 'c3', 'Nf6']),
    _Opening('C55', "Two Knights Defence", ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Nf6']),
    _Opening('C56', "Two Knights: Fried Liver Attack", ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Nf6', 'd4', 'exd4', 'O-O']),
    _Opening('C57', "Two Knights: Traxler", ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Nf6', 'Ng5', 'Bc5']),
    _Opening('C60', "Ruy Lopez", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']),
    _Opening('C61', "Ruy Lopez: Bird's Defence", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'Nd4']),
    _Opening('C62', "Ruy Lopez: Old Steinitz", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'd6']),
    _Opening('C63', "Ruy Lopez: Schliemann", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'f5']),
    _Opening('C64', "Ruy Lopez: Classical", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'Bc5']),
    _Opening('C65', "Ruy Lopez: Berlin Defence", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'Nf6']),
    _Opening('C67', "Ruy Lopez: Berlin, Rio de Janeiro", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'Nf6', 'O-O', 'Nxe4']),
    _Opening('C68', "Ruy Lopez: Exchange", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Bxc6']),
    _Opening('C70', "Ruy Lopez: Morphy Defence", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ba4']),
    _Opening('C78', "Ruy Lopez: Archangel", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ba4', 'Nf6', 'O-O', 'b5', 'Bb3', 'Bc5']),
    _Opening('C80', "Ruy Lopez: Open (Marshall Attack)", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ba4', 'Nf6', 'O-O', 'Nxe4']),
    _Opening('C84', "Ruy Lopez: Closed", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ba4', 'Nf6', 'O-O', 'Be7']),
    _Opening('C89', "Ruy Lopez: Marshall Attack", ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ba4', 'Nf6', 'O-O', 'Be7', 'Re1', 'b5', 'Bb3', 'O-O', 'c3', 'd5']),

    // D — Closed games
    _Opening('D00', "Queen's Pawn Game", ['d4', 'd5']),
    _Opening('D01', "Richter-Veresov Attack", ['d4', 'd5', 'Nc3', 'Nf6', 'Bg5']),
    _Opening('D02', "Queen's Pawn: London System", ['d4', 'd5', 'Nf3']),
    _Opening('D06', "Queen's Gambit", ['d4', 'd5', 'c4']),
    _Opening('D07', "Queen's Gambit: Chigorin", ['d4', 'd5', 'c4', 'Nc6']),
    _Opening('D10', "Slav Defence", ['d4', 'd5', 'c4', 'c6']),
    _Opening('D11', "Slav: Exchange", ['d4', 'd5', 'c4', 'c6', 'Nf3', 'Nf6']),
    _Opening('D15', "Slav: Accepted", ['d4', 'd5', 'c4', 'c6', 'Nc3', 'Nf6', 'Nf3', 'dxc4']),
    _Opening('D20', "Queen's Gambit Accepted", ['d4', 'd5', 'c4', 'dxc4']),
    _Opening('D30', "Queen's Gambit Declined", ['d4', 'd5', 'c4', 'e6']),
    _Opening('D31', "QGD: Semi-Slav", ['d4', 'd5', 'c4', 'e6', 'Nc3', 'c6']),
    _Opening('D35', "QGD: Exchange", ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'cxd5', 'exd5']),
    _Opening('D37', "QGD: Classical", ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'Nf3', 'Be7']),
    _Opening('D43', "QGD: Semi-Slav, Moscow", ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'Nf3', 'c6', 'Bg5']),
    _Opening('D50', "QGD: Modern", ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'Bg5']),
    _Opening('D70', "Neo-Grünfeld", ['d4', 'Nf6', 'c4', 'g6', 'd5']),
    _Opening('D80', "Grünfeld Defence", ['d4', 'Nf6', 'c4', 'g6', 'Nc3', 'd5']),
    _Opening('D85', "Grünfeld: Exchange", ['d4', 'Nf6', 'c4', 'g6', 'Nc3', 'd5', 'cxd5', 'Nxd5', 'e4', 'Nxc3', 'bxc3']),
    _Opening('D90', "Grünfeld: Russian", ['d4', 'Nf6', 'c4', 'g6', 'Nc3', 'd5', 'Nf3']),

    // E — Indian defences
    _Opening('E00', "Catalan Opening", ['d4', 'Nf6', 'c4', 'e6', 'g3']),
    _Opening('E10', "Queen's Indian Accelerated", ['d4', 'Nf6', 'c4', 'e6', 'Nf3']),
    _Opening('E12', "Queen's Indian Defence", ['d4', 'Nf6', 'c4', 'e6', 'Nf3', 'b6']),
    _Opening('E20', "Nimzo-Indian Defence", ['d4', 'Nf6', 'c4', 'e6', 'Nc3', 'Bb4']),
    _Opening('E21', "Nimzo-Indian: Three Knights", ['d4', 'Nf6', 'c4', 'e6', 'Nc3', 'Bb4', 'Nf3']),
    _Opening('E32', "Nimzo-Indian: Classical", ['d4', 'Nf6', 'c4', 'e6', 'Nc3', 'Bb4', 'Qc2']),
    _Opening('E40', "Nimzo-Indian: Normal", ['d4', 'Nf6', 'c4', 'e6', 'Nc3', 'Bb4', 'e3']),
    _Opening('E43', "Nimzo-Indian: Fischer", ['d4', 'Nf6', 'c4', 'e6', 'Nc3', 'Bb4', 'e3', 'b6']),
    _Opening('E46', "Nimzo-Indian: Reshevsky", ['d4', 'Nf6', 'c4', 'e6', 'Nc3', 'Bb4', 'e3', 'O-O']),
    _Opening('E60', "King's Indian Defence", ['d4', 'Nf6', 'c4', 'g6']),
    _Opening('E62', "King's Indian: Fianchetto", ['d4', 'Nf6', 'c4', 'g6', 'Nc3', 'Bg7', 'Nf3', 'O-O', 'g3']),
    _Opening('E70', "King's Indian: Averbakh", ['d4', 'Nf6', 'c4', 'g6', 'Nc3', 'Bg7', 'e4', 'd6', 'Be2', 'O-O', 'Bg5']),
    _Opening('E80', "King's Indian: Sämisch", ['d4', 'Nf6', 'c4', 'g6', 'Nc3', 'Bg7', 'e4', 'd6', 'f3']),
    _Opening('E90', "King's Indian: Classical", ['d4', 'Nf6', 'c4', 'g6', 'Nc3', 'Bg7', 'e4', 'd6', 'Nf3']),
    _Opening('E97', "King's Indian: Mar del Plata", ['d4', 'Nf6', 'c4', 'g6', 'Nc3', 'Bg7', 'e4', 'd6', 'Nf3', 'O-O', 'Be2', 'e5', 'O-O', 'Nc6']),
  ];
}
