import 'dart:collection';
import 'dart:js_interop';

import 'package:piecemeal/piecemeal.dart';
import 'package:web/web.dart' as web;

const _tileSize = 32;

enum Tile { floor, solid, wall, hDoor, vDoor }

enum CellType { open, solid, door }

class Cell {
  static const _noRegion = -1;

  CellType type = CellType.solid;
  int region = _noRegion;

  bool get isSolid => type == CellType.solid;
  bool get hasRegion => region != _noRegion;
}

const _wigglePercent = 50;

final _tileset = web.HTMLImageElement()..src = "/image/2014/12/tiles.png";

main() {
  _tileset.onLoad.listen(_start);
}

_start(_) {
  Dungeon("enchilada");

  var rooms = RoomsDungeon();
  rooms.slider("attempts", (value) => rooms.roomTries = value);

  var deadEnds = DeadEndsDungeon();
  deadEnds.slider("dead-end-open", (value) => deadEnds.leaveOpen = value);

  MazeFillDungeon();
  ConnectorsDungeon();

  Dungeon("giant", cellSize: 4, speed: 8, roomTries: 600, maxRoomSize: 8);
}

T query<T>(String selector) => web.document.querySelector(selector) as T;

class RoomsDungeon extends Dungeon {
  RoomsDungeon() : super("rooms") {
    showRegions = false;
  }

  @override
  bool update() {
    return _addRoom();
  }
}

class DeadEndsDungeon extends Dungeon {
  @override
  bool get showRegions => false;
  int leaveOpen = 1000;

  DeadEndsDungeon() : super("dead-ends", speed: 4) {
    showRegions = false;
    roomTries = 0;
  }

  @override
  void reset() {
    super.reset();

    _startMazeCell();
    _growMaze(fast: true);
    _findOpenCells();
  }

  @override
  bool update() {
    if (_openCells.length < leaveOpen) {
      return false;
    }

    return _removeDeadEnd();
  }
}

class MazeFillDungeon extends Dungeon {
  MazeFillDungeon() : super("maze-fill", roomTries: 600);

  @override
  bool update() => _addRoom() || _growMaze() || _startMaze();

  @override
  void _findConnectors() {}
}

class ConnectorsDungeon extends Dungeon {
  ConnectorsDungeon() : super("connectors");

  Iterator<Vec>? _tiles;

  @override
  bool update() {
    if (_tiles == null) {
      _addRoom(fast: true);

      while (_startMaze()) {
        _growMaze(fast: true);
      }
      _findOpenCells();

      _tiles = _cells.bounds.inflate(-1).iterator;
      return true;
    }

    return _findConnector();
  }

  @override
  void _startMerge() {}

  bool _findConnector() {
    while (_tiles!.moveNext()) {
      var pos = _tiles!.current;

      // Can't already be part of a region.
      if (_cells[pos].hasRegion) continue;

      var regions = _regionsTouching(pos);
      if (regions.length < 2) continue;

      _drawConnector(pos);
      return true;
    }

    _tiles = null;
    return false;
  }
}

class Dungeon {
  static const _canvasWidth = 992;
  static const _canvasHeight = 744;

  final web.HTMLCanvasElement _canvas;
  late final web.CanvasRenderingContext2D _context = _canvas.context2D;

  final int cellSize;
  final int speed;
  int roomTries = 0;
  final int maxRoomSize;

  bool _running = false;

  final Array2D<Cell> _cells;

  final _rooms = <Rect>[];
  int _roomTriesLeft = 0;

  int _currentRegion = 0;

  /// Starting position of the current maze.
  int _mazeStartX = 0;
  int _mazeStartY = 0;

  Direction? _lastMazeDir;

  /// The open cells for the current maze being generated.
  final List<Vec> _mazeCells = [];

  final List<Vec> _connectors = [];

  final _mergeCells = Queue<Vec>();

  final _openCells = <Vec>[];
  int? _deadEndSeek;

  num _scale = 1.0;

  bool showRegions = true;

  Dungeon(
    String id, {
    this.cellSize = 16,
    this.speed = 2,
    this.roomTries = 200,
    this.maxRoomSize = 5,
  }) : _canvas = query<web.HTMLCanvasElement>("#$id"),
       _cells = Array2D.generated(
         _canvasWidth ~/ cellSize,
         _canvasHeight ~/ cellSize,
         (_) => Cell(),
       ) {
    // Handle high-resolution (i.e. retina) displays.
    _scale = web.window.devicePixelRatio;
    _canvas.width = (_canvasWidth * _scale).toInt();
    _canvas.height = (_canvasHeight * _scale).toInt();

    _canvas.onClick.listen((_) {
      reset();
      start();
    });

    reset();
  }

  void start() {
    if (!_running) web.window.requestAnimationFrame(tick.toJS);
    _running = true;
  }

  void tick(num time) {
    for (var i = 0; i < speed; i++) {
      if (!update()) {
        _running = false;
        return;
      }
    }

    web.window.requestAnimationFrame(tick.toJS);
  }

  void reset() {
    _roomTriesLeft = roomTries;
    _rooms.clear();

    _currentRegion = 0;

    _mazeStartX = 1;
    _mazeStartY = 1;
    _lastMazeDir = null;

    _connectors.clear();

    /// The open cells for the current maze being generated.
    _mazeCells.clear();
    _mergeCells.clear();
    _openCells.clear();

    _context.fillStyle = 'red'.toJS;
    _context.fillRect(0, 0, _canvas.width, _canvas.height);
    for (var pos in _cells.bounds) {
      _carve(pos, type: CellType.solid, region: Cell._noRegion);
    }
  }

  bool update() {
    return _addRoom() ||
        _growMaze() ||
        _startMaze() ||
        _fillMerge() ||
        _mergeRegion() ||
        _removeDeadEnd();
  }

  void slider(String id, Function(int value) effect) {
    var element = query<web.HTMLInputElement>("#$id");
    var output = query<web.HTMLOutputElement>("#$id-output");

    element.onChange.listen((_) {
      effect(int.parse(element.value));
      output.value = element.value;
      reset();
      start();
    });
  }

  bool _addRoom({bool fast = false}) {
    if (_roomTriesLeft <= 0) return false;

    while (--_roomTriesLeft >= 0) {
      var width = rng.range(2, maxRoomSize) * 2 + 1;
      var height = rng.range(2, maxRoomSize) * 2 + 1;

      var x = rng.range(0, (_cells.width - width) ~/ 2) * 2 + 1;
      var y = rng.range(0, (_cells.height - height) ~/ 2) * 2 + 1;

      var room = Rect(x, y, width, height);

      var overlaps = false;
      for (var other in _rooms) {
        if (room.distanceTo(other) <= 0) {
          overlaps = true;
          break;
        }
      }

      if (overlaps) continue;

      _rooms.add(room);
      _currentRegion++;
      room.forEach(_carve);

      if (!fast) return true;
    }

    return false;
  }

  bool _startMaze() {
    if (_mazeStartY >= _cells.height - 1) return false;

    // Find the next solid place to start a maze.
    while (!_cells.get(_mazeStartX, _mazeStartY).isSolid) {
      _mazeStartX += 2;
      if (_mazeStartX >= _cells.width - 1) {
        _mazeStartX = 1;
        _mazeStartY += 2;

        // Stop if we've scanned the whole dungeon.
        if (_mazeStartY >= _cells.height - 1) {
          _findConnectors();
          return false;
        }
      }
    }

    _startMazeCell();
    return true;
  }

  void _startMazeCell() {
    var pos = Vec(_mazeStartX, _mazeStartY);
    _mazeCells.add(pos);
    _currentRegion++;
    _carve(pos);
  }

  /// Implementation of the "growing tree" algorithm from here:
  /// http://www.astrolog.org/labyrnth/algrithm.htm.
  bool _growMaze({bool fast = false}) {
    if (_mazeCells.isEmpty) return false;

    while (_mazeCells.isNotEmpty) {
      var cell = _mazeCells.last;

      // See which adjacent cells are open.
      var openDirs = <Direction>[];

      for (var dir in Direction.cardinal) {
        // Must end in bounds.
        if (!_cells.bounds.contains(cell + dir * 3)) continue;

        // Destination must not be open.
        if (!_cells[cell + dir * 2].isSolid) continue;

        openDirs.add(dir);
      }

      if (openDirs.isEmpty) {
        // No adjacent uncarved cells.
        _mazeCells.removeLast();
        continue;
      }

      // TODO: Simplify.
      Direction dir;
      if (openDirs.contains(_lastMazeDir) && rng.range(100) > _wigglePercent) {
        dir = _lastMazeDir!;
      } else {
        dir = rng.item(openDirs);
      }

      _lastMazeDir = dir;

      _carve(cell + dir);
      _carve(cell + dir + dir);

      _mazeCells.add(cell + dir + dir);

      // Made progress, so refresh.
      if (!fast) return true;
    }

    return false;
  }

  void _findConnectors() {
    for (var pos in _cells.bounds.inflate(-1)) {
      // Can't already be part of a region.
      if (_cells[pos].hasRegion) continue;

      var regions = _regionsTouching(pos);
      if (regions.length < 2) continue;

      _connectors.add(pos);
    }

    _connectors.shuffle();

    // Start the merge by turning one room into the merge color.
    _startMerge();
  }

  void _startMerge() {
    _mergeCells.add(_rooms.first.center);
    _carve(_rooms.first.center, region: Cell._noRegion);
  }

  bool _mergeRegion() {
    if (_connectors.isEmpty) return false;

    // Find a connector that's touching the merged area.
    Vec? connector;
    Set<int>? merged;
    for (var i = 0; i < _connectors.length; i++) {
      merged = _regionsTouching(_connectors[i]);
      if (merged.contains(Cell._noRegion)) {
        connector = _connectors[i];
        _connectors.removeAt(i);
        break;
      }
    }

    // Remove any connectors that aren't needed anymore.
    _connectors.removeWhere((pos) {
      // Don't allow connectors right next to each other.
      if (connector! - pos < 2) return true;

      // If the connector no long spans different regions, we don't need it.
      var regions = _regionsTouching(
        pos,
      ).where((region) => !merged!.contains(region));
      if (regions.isNotEmpty) return false;

      // This connecter isn't needed, but connect it occasionally so that the
      // dungeon isn't singly-connected.
      if (rng.oneIn(50)) _carve(pos, type: CellType.door);

      return true;
    });

    // Start the merge floodfill.
    _mergeCells.add(connector!);
    _carve(connector, type: CellType.door);
    return true;
  }

  bool _fillMerge() {
    if (_mergeCells.isEmpty) return false;

    while (_mergeCells.isNotEmpty) {
      var pos = _mergeCells.removeFirst();

      for (var dir in Direction.cardinal) {
        var here = pos + dir;
        if (!_cells[here].hasRegion) continue;

        _carve(here, region: Cell._noRegion);
        _mergeCells.add(here);
      }

      break;
    }

    // Done merging, so get ready to remove the dead ends.
    if (_mergeCells.isEmpty && _connectors.isEmpty) {
      _findOpenCells();
    }

    return true;
  }

  void _findOpenCells() {
    for (var pos in _cells.bounds.inflate(-1)) {
      if (!_cells[pos].isSolid) _openCells.add(pos);
    }

    _openCells.shuffle();
    _deadEndSeek = 0;
  }

  bool _removeDeadEnd() {
    if (_openCells.isEmpty) return false;

    var start = _deadEndSeek;

    while (true) {
      var pos = _openCells[_deadEndSeek!];

      var exits = 0;
      for (var dir in Direction.cardinal) {
        if (!_cells[pos + dir].isSolid) exits++;
      }

      // If it only has one exit, it's a dead end.
      if (exits == 1) {
        _carve(pos, type: CellType.solid);
        _openCells.removeAt(_deadEndSeek!);
        if (_deadEndSeek == _openCells.length) _deadEndSeek = 0;
        return true;
      }

      // Move on to the next candidate.
      _deadEndSeek = (_deadEndSeek! + 1) % _openCells.length;

      // If we did a full cycle and didn't find a dead end, there must not be
      // any more.
      if (_deadEndSeek == start) {
        _openCells.clear();
        break;
      }
    }

    return false;
  }

  Set<int> _regionsTouching(Vec pos) {
    return {
      for (var dir in Direction.cardinal)
        if (_cells[pos + dir].type == CellType.open) _cells[pos + dir].region,
    };
  }

  void _carve(Vec pos, {CellType type = CellType.open, int? region}) {
    if (region == null) {
      if (type == CellType.open && showRegions) {
        region = _currentRegion;
      } else {
        region = Cell._noRegion;
      }
    }

    _cells[pos].type = type;
    if (type == CellType.open) _cells[pos].region = region;

    switch (type) {
      case CellType.open:
        _draw(pos.x, pos.y, Tile.floor);

        // Make solid above this a wall.
        if (pos.y > 0 && _cells.get(pos.x, pos.y - 1).isSolid) {
          _draw(pos.x, pos.y - 1, Tile.wall);
        }

        // Show the region color.
        if (region != Cell._noRegion) {
          _context.fillStyle = 'hsla(${region * 17 % 360}, 80%, 20%, 0.4)'.toJS;
          _context.fillRect(
            pos.x * cellSize * _scale,
            pos.y * cellSize * _scale,
            cellSize * _scale,
            cellSize * _scale,
          );
        }
      case CellType.solid:
        // Draw the wall.
        if (pos.y < _cells.height - 1 &&
            !_cells.get(pos.x, pos.y + 1).isSolid) {
          _draw(pos.x, pos.y, Tile.wall);
        } else {
          _draw(pos.x, pos.y, Tile.solid);
        }

        // If the tile above this was a wall, it's solid now.
        if (pos.y > 0 && _cells.get(pos.x, pos.y - 1).isSolid) {
          _draw(pos.x, pos.y - 1, Tile.solid);
        }
      case CellType.door:
        // Draw the door.
        if (_cells.get(pos.x - 1, pos.y).isSolid) {
          _draw(pos.x, pos.y, Tile.hDoor);
        } else {
          _draw(pos.x, pos.y, Tile.vDoor);

          // Make solid above this a wall.
          _draw(pos.x, pos.y - 1, Tile.wall);
        }
    }
  }

  void _draw(int x, int y, Tile tile) {
    _context.drawImage(
      _tileset,
      tile.index * _tileSize,
      0,
      _tileSize,
      _tileSize,
      x * cellSize * _scale,
      y * cellSize * _scale,
      cellSize * _scale,
      cellSize * _scale,
    );
  }

  void _drawConnector(Vec pos) {
    _context.fillStyle = '#7dc45e'.toJS;
    _context.fillRect(
      (pos.x * cellSize + 4) * _scale,
      (pos.y * cellSize + 4) * _scale,
      (cellSize - 8) * _scale,
      (cellSize - 8) * _scale,
    );
  }
}
