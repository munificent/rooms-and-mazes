import 'dart:collection';
import 'dart:js_interop';

import 'package:piecemeal/piecemeal.dart';
import 'package:web/web.dart' as web;

const _tileSize = 12;

enum Tile { floor, solid, wall, hDoor, vDoor }

const _cellSolid = 0;
const _cellMerged = -1;
const _cellDoor = -2;

const _wigglePercent = 50;

final _tileset = web.HTMLImageElement()..src = "/image/2014/12/tiles.png";

main() {
  _tileset.onLoad.listen(_start);
}

_start(_) {
  Dungeon("enchilada");

  var rooms = RoomsDungeon();
  slider(rooms, "attempts", (value) => rooms.roomTries = value);

  var deadEnds = DeadEndsDungeon();
  slider(deadEnds, "dead-end-open", (value) => deadEnds.leaveOpen = value);

  MazeFillDungeon();
  ConnectorsDungeon();

  Dungeon("giant", cellSize: 2, speed: 8, roomTries: 600, maxRoomSize: 8);
}

T _query<T>(String selector) => web.document.querySelector(selector) as T;

void slider(Dungeon dungeon, String id, Function(int value) effect) {
  var element = _query<web.HTMLInputElement>("#$id");
  var output = _query<web.HTMLOutputElement>("#$id-output");

  element.onChange.listen((_) {
    effect(int.parse(element.value));
    output.value = element.value;
    dungeon.reset();
    dungeon.start();
  });
}

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

      _tiles = _floors.bounds.inflate(-1).iterator;
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
      if (_floors[pos] > _cellSolid) continue;

      var regions = _getRegionsTouching(pos);
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

  final Array2D<int> _floors;

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
    this.cellSize = 6,
    this.speed = 2,
    this.roomTries = 200,
    this.maxRoomSize = 5,
  }) : _canvas = _query<web.HTMLCanvasElement>("#$id"),
       _floors = Array2D<int>(
         _canvasWidth ~/ cellSize,
         _canvasHeight ~/ cellSize,
         _cellSolid,
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

    for (var pos in _floors.bounds) {
      _carve(pos, _cellSolid);
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

  bool _addRoom({bool fast = false}) {
    if (_roomTriesLeft <= 0) return false;

    while (--_roomTriesLeft >= 0) {
      var width = rng.range(2, maxRoomSize) * 2 + 1;
      var height = rng.range(2, maxRoomSize) * 2 + 1;

      var x = rng.range(0, (_floors.width - width) ~/ 2) * 2 + 1;
      var y = rng.range(0, (_floors.height - height) ~/ 2) * 2 + 1;

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
    if (_mazeStartY >= _floors.height - 1) return false;

    // Find the next solid place to start a maze.
    while (_floors.get(_mazeStartX, _mazeStartY) != _cellSolid) {
      _mazeStartX += 2;
      if (_mazeStartX >= _floors.width - 1) {
        _mazeStartX = 1;
        _mazeStartY += 2;

        // Stop if we've scanned the whole dungeon.
        if (_mazeStartY >= _floors.height - 1) {
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
        if (!_floors.bounds.contains(cell + dir * 3)) continue;

        // Destination must not be open.
        if (_floors[cell + dir * 2] != _cellSolid) continue;

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
      _carve(cell + dir * 2);

      _mazeCells.add(cell + dir * 2);

      // Made progress, so refresh.
      if (!fast) return true;
    }

    return false;
  }

  void _findConnectors() {
    for (var pos in _floors.bounds.inflate(-1)) {
      // Can't already be part of a region.
      if (_floors[pos] > _cellSolid) continue;

      var regions = _getRegionsTouching(pos);
      if (regions.length < 2) continue;

      _connectors.add(pos);
    }

    _connectors.shuffle();

    // Start the merge by turning one room into the merge color.
    _startMerge();
  }

  void _startMerge() {
    _mergeCells.add(_rooms.first.center);
    _carve(_rooms.first.center, _cellMerged);
  }

  bool _mergeRegion() {
    if (_connectors.isEmpty) return false;

    // Find a connector that's touching the merged area.
    Vec? connector;
    Set<int>? merged;
    for (var i = 0; i < _connectors.length; i++) {
      merged = _getRegionsTouching(_connectors[i]);
      if (merged.contains(_cellMerged)) {
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
      var regions = _getRegionsTouching(
        pos,
      ).where((region) => !merged!.contains(region));
      if (regions.isNotEmpty) return false;

      // This connecter isn't needed, but connect it occasionally so that the
      // dungeon isn't singly-connected.
      if (rng.oneIn(50)) _carve(pos, _cellDoor);

      return true;
    });

    // Start the merge floodfill.
    _mergeCells.add(connector!);
    _carve(connector, _cellDoor);
    return true;
  }

  bool _fillMerge() {
    if (_mergeCells.isEmpty) return false;

    while (_mergeCells.isNotEmpty) {
      var pos = _mergeCells.removeFirst();

      for (var dir in Direction.cardinal) {
        var here = pos + dir;
        if (_floors[here] <= _cellSolid) continue;

        _carve(here, _cellMerged);
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
    for (var pos in _floors.bounds.inflate(-1)) {
      if (_floors[pos] != _cellSolid) _openCells.add(pos);
    }

    _openCells.shuffle();
    _deadEndSeek = 0;
  }

  bool _removeDeadEnd() {
    if (_openCells.isEmpty) return false;

    var start = _deadEndSeek;

    while (true) {
      var pos = _openCells[_deadEndSeek!];

      // If it only has one exit, it's a dead end.
      var exits = 0;
      for (var dir in Direction.cardinal) {
        if (_floors[pos + dir] != _cellSolid) exits++;
      }

      if (exits == 1) {
        _carve(pos, _cellSolid);
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

  Set<int> _getRegionsTouching(Vec pos) {
    var regions = <int>{};
    for (var dir in Direction.cardinal) {
      var region = _floors[pos + dir];
      if (region != _cellSolid) regions.add(region);
    }

    return regions;
  }

  void _carve(Vec pos, [int? value]) {
    if (value == null) {
      if (showRegions) {
        value = _currentRegion;
      } else {
        value = _cellMerged;
      }
    }

    _floors[pos] = value;

    if (value > _cellSolid) {
      // Open region.
      _drawTile(pos.x, pos.y, Tile.floor);

      _context.fillStyle = 'hsla(${value * 17 % 360}, 100%, 20%, 0.5)'.toJS;
      _context.fillRect(
        pos.x * cellSize * _scale,
        pos.y * cellSize * _scale,
        cellSize * _scale,
        cellSize * _scale,
      );
    } else if (value == _cellSolid) {
      // Draw the wall.
      if (pos.y < _floors.height - 1 &&
          _floors.get(pos.x, pos.y + 1) != _cellSolid) {
        _drawTile(pos.x, pos.y, Tile.wall);
      } else {
        _drawTile(pos.x, pos.y, Tile.solid);
      }

      // If the tile above this was a wall, it's solid now.
      if (pos.y > 0 && _floors.get(pos.x, pos.y - 1) == _cellSolid) {
        _drawTile(pos.x, pos.y - 1, Tile.solid);
      }
    } else if (value == _cellDoor) {
      // Draw the door.
      if (_floors.get(pos.x - 1, pos.y) == _cellSolid) {
        _drawTile(pos.x, pos.y, Tile.hDoor);
      } else {
        _drawTile(pos.x, pos.y, Tile.vDoor);
      }

      // Make solid above this a wall.
      if (pos.y > 0 && _floors.get(pos.x, pos.y - 1) == _cellSolid) {
        _drawTile(pos.x, pos.y - 1, Tile.wall);
      }
    } else {
      _drawTile(pos.x, pos.y, Tile.floor);

      // Make solid above this a wall.
      if (pos.y > 0 && _floors.get(pos.x, pos.y - 1) == _cellSolid) {
        _drawTile(pos.x, pos.y - 1, Tile.wall);
      }
    }
  }

  void _drawTile(int x, int y, Tile tile) {
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
    _context.fillStyle = '#ca8'.toJS;
    _context.fillRect(
      (pos.x * cellSize + 2) * _scale,
      (pos.y * cellSize + 2) * _scale,
      (cellSize - 4) * _scale,
      (cellSize - 4) * _scale,
    );
  }
}
