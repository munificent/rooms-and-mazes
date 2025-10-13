import 'dart:collection';
import 'dart:js_interop';
import 'dart:math';

import 'package:piecemeal/piecemeal.dart';
import 'package:web/web.dart' as web;

T query<T>(String selector) => web.document.querySelector(selector) as T;

class Dungeon {
  /// The size of the canvas in logical pixels, based on the design of my blog.
  static const _canvasWidth = 992;
  static const _canvasHeight = 744;

  /// How large a room can be.
  int maxRoomSize;

  /// How many rooms to try to place.
  int roomTries;

  /// Percentage chance of the maze builder picking a random direction instead
  /// of trying to continue in a straight line.
  int wigglePercent;

  /// How big each cell of the dungeon is in pixels.
  final int cellSize;

  /// How many animation steps to take per rendered frame.
  int speed;

  /// Whether to show a color for each region.
  final bool showRegions;

  final web.HTMLCanvasElement _canvas;
  late final web.CanvasRenderingContext2D _context = _canvas.context2D;

  num _pixelScale = 1.0;

  /// The cells may not evenly divide the canvas size. In that case, we'll
  /// shift the dungeon over so that it's still centered in the canvas.
  Vec _drawOffset = Vec.zero;

  final Array2D<Cell> _cells;

  int _currentRegion = 0;

  final List<Vec> _connectors = [];

  Vec _mergeStart = Vec.zero;

  Iterator<void>? _steps;

  /// The absolute time in milliseconds when the last frame was drawn.
  ///
  /// We try to animate no faster than 60 FPS but will go slower if the refresh
  /// rate is lower than that.
  num _lastFrameTime = 0;

  Dungeon(
    String id, {
    this.cellSize = 12,
    this.speed = 2,
    this.roomTries = 100,
    this.wigglePercent = 50,
    this.maxRoomSize = 10,
    this.showRegions = true,
  }) : _canvas = query<web.HTMLCanvasElement>("#$id"),
       _cells = Array2D.generated(
         _dungeonCells(_canvasWidth, cellSize),
         _dungeonCells(_canvasHeight, cellSize),
         (_) => Cell(),
       ) {
    // Handle high-resolution displays.
    _pixelScale = web.window.devicePixelRatio;
    _canvas.width = (_canvasWidth * _pixelScale).toInt();
    _canvas.height = (_canvasHeight * _pixelScale).toInt();

    _drawOffset = Vec(
      (_canvasWidth - _cells.width * cellSize) ~/ 2,
      (_canvasHeight - _cells.height * cellSize) ~/ 2,
    );

    _canvas.onClick.listen((_) {
      reset(start: true);
    });

    reset();
  }

  /// Calculate the number of cells for one of the dungeon's dimensions.
  ///
  /// Given the [canvasSize], we fit as many cells of [cellSize] that fit
  /// rounded down to the nearest odd number because the rooms and mazes
  /// algorithm aligns things to a 2-cell grid.
  static int _dungeonCells(int canvasSize, int cellSize) {
    var cells = canvasSize ~/ cellSize;
    if (cells % 2 == 0) cells--;
    return cells;
  }

  Iterable<void> run() sync* {
    yield* placeRooms();
    yield* placeMazes();
    for (var _ in findConnectors(draw: false)) {}
    yield* mergeRegions();
    yield* removeDeadEnds();
  }

  void tick(num time) {
    // Reset the time if this is the first tick.
    if (_lastFrameTime == 0) _lastFrameTime = time;

    // If it's been at least 1/60th of a second since we last animated a frame,
    // then advance another.
    var elapsed = time - _lastFrameTime;
    if (_lastFrameTime == 0 || elapsed >= 1000 / 60) {
      for (var i = 0; i < speed && _steps != null; i++) {
        if (_steps case var steps?) {
          if (!steps.moveNext()) {
            _steps = null;
          }
        }
      }

      _lastFrameTime = time;
    }

    if (_steps != null) web.window.requestAnimationFrame(tick.toJS);
  }

  void reset({bool start = false}) {
    // Clear the dungeon.
    for (var pos in _cells.bounds) {
      _cells[pos].type = CellType.solid;
      _cells[pos].region = Cell.noRegion;
    }

    _context.fillStyle = '#1c1a2b'.toJS;
    _context.fillRect(0, 0, _canvas.width, _canvas.height);

    _currentRegion = 0;
    _steps = run().iterator;
    if (start) {
      web.window.requestAnimationFrame(tick.toJS);
      _lastFrameTime = 0;
    }
  }

  void slider(String id, Function(int value) effect, {bool reset = true}) {
    var element = query<web.HTMLInputElement>("#$id");
    var output = query<web.HTMLOutputElement>("#$id-output");

    element.onChange.listen((_) {
      effect(int.parse(element.value));
      output.value = element.value;
      if (reset) this.reset(start: true);
    });
  }

  /// Place random rooms.
  Iterable<void> placeRooms() sync* {
    var rooms = <Rect>[];

    for (var i = 0; i < roomTries; i++) {
      var width = rng.range(1, (maxRoomSize + 1) ~/ 2) * 2 + 1;
      var height = rng.range(1, (maxRoomSize + 1) ~/ 2) * 2 + 1;

      var x = rng.range(0, (_cells.width - width) ~/ 2) * 2 + 1;
      var y = rng.range(0, (_cells.height - height) ~/ 2) * 2 + 1;

      var room = Rect(x, y, width, height);

      var overlaps = false;
      for (var other in rooms) {
        if (room.distanceTo(other) <= 0) {
          overlaps = true;
          break;
        }
      }

      // This room overlaps another one so discard it.
      if (overlaps) continue;

      rooms.add(room);
      _currentRegion++;
      room.forEach(_carve);
      yield null;
    }

    // If we merge regions later, start in the middle of the first room.
    _mergeStart = rooms.first.center;
  }

  /// Add mazes to every place in the dungeon where they will fit.
  Iterable<void> placeMazes() sync* {
    for (var startY = 1; startY < _cells.height - 1; startY += 2) {
      for (var startX = 1; startX < _cells.width - 1; startX += 2) {
        if (_cells.get(startX, startY).isSolid) {
          yield* growMaze(Vec(startX, startY));
        }
      }
    }
  }

  /// Expand a maze starting at [start], filling in all reachable solid tiles
  /// from it.
  Iterable<void> growMaze(Vec start) sync* {
    _currentRegion++;
    _carve(start);

    var mazeCells = [start];
    var currentDirection = Direction.none;
    while (mazeCells.isNotEmpty) {
      var cell = mazeCells.last;

      // Find the adjacent cells that we can carve into.
      var openDirs = [
        for (var dir in Direction.cardinal)
          if (_cells.bounds.contains(cell + dir * 3) && // Must end in bounds.
              _cells[cell + dir * 2].isSolid) // Destination must not be open.
            dir,
      ];

      if (openDirs.isNotEmpty) {
        var direction = currentDirection;
        if (!openDirs.contains(currentDirection) ||
            rng.range(100) <= wigglePercent) {
          direction = rng.item(openDirs);
          currentDirection = direction;
        }

        _carve(cell + direction);
        _carve(cell + direction * 2);
        mazeCells.add(cell + direction * 2);
        yield null;
      } else {
        // Dead end, so discard it.
        mazeCells.removeLast();
      }
    }
  }

  /// Find all connectors: solid cells that are between multiple different
  /// regions.
  Iterable<void> findConnectors({bool draw = false}) sync* {
    for (var pos in _cells.bounds.inflate(-1)) {
      // A connector must be a solid tile we can open.
      if (!_cells[pos].isSolid) continue;

      // And it must touch two different regions.
      var regions = _regionsTouching(pos);
      if (regions.length < 2) continue;

      _connectors.add(pos);

      if (draw) {
        _draw(
          pos.x,
          pos.y,
          _cells.get(pos.x, pos.y - 1).isSolid
              ? Tile.vConnector
              : Tile.hConnector,
        );
      }
      yield null;
    }

    rng.shuffle(_connectors);
  }

  Set<int> _regionsTouching(Vec pos) {
    return {
      for (var dir in Direction.cardinal)
        if (_cells[pos + dir].type == CellType.open) _cells[pos + dir].region,
    };
  }

  /// Merge all of the regions into one connected one by adding doors between
  /// different regions.
  Iterable<void> mergeRegions() sync* {
    // Flood fill the starting room.
    yield* _floodFill(_mergeStart, CellType.open);

    while (_connectors.isNotEmpty) {
      // Find a connector that's touching the already-merged cells.
      Vec? connector;

      Set<int>? merged;
      rng.shuffle(_connectors);
      for (var i = 0; i < _connectors.length; i++) {
        merged = _regionsTouching(_connectors[i]);
        if (merged.contains(Cell.noRegion)) {
          connector = _connectors[i];
          _connectors.removeAt(i);
          break;
        }
      }

      // Remove any connectors that aren't needed anymore.
      _connectors.removeWhere((pos) {
        // Don't allow multiple doors right next to each other.
        if (connector! - pos < 2) return true;

        // If the connector no long spans different regions, we don't need it.
        var regions = _regionsTouching(
          pos,
        ).where((region) => !merged!.contains(region));

        // This connecter isn't needed, but connect it occasionally so that the
        // dungeon isn't singly-connected.
        var addLoop = rng.oneIn(50);

        return regions.isEmpty && !addLoop;
      });

      // Make a door to the region being merged and flood fill it.
      yield* _floodFill(connector!, CellType.door);
    }
  }

  /// Clear the region of all cells touching [start].
  Iterable<void> _floodFill(Vec start, CellType type) sync* {
    // Clear the region of the starting cell.
    var mergeCells = Queue<Vec>();
    mergeCells.add(start);
    _carve(start, type: type, region: Cell.noRegion);

    // Do a breadth-first flood fill of neighboring cells until we run out of
    // ones to merge.
    var stepsToYield = 1;
    var step = 0;
    while (mergeCells.isNotEmpty) {
      var pos = mergeCells.removeFirst();
      for (var dir in Direction.cardinal) {
        var neighbor = pos + dir;
        if (_cells[neighbor].hasRegion) {
          _carve(neighbor, region: Cell.noRegion);
          mergeCells.add(neighbor);
          // yield null;
        }
      }

      if (step++ > stepsToYield) {
        step = 0;
        stepsToYield = max(1, mergeCells.length ~/ 2);
        yield null;
      }
    }
  }

  Iterable<void> removeDeadEnds({int? max}) sync* {
    // Find all the current dead end cells.
    var deadEnds = [
      for (var pos in _cells.bounds.inflate(-1))
        if (_isDeadEnd(pos)) pos,
    ];

    var removed = 0;
    while (deadEnds.isNotEmpty) {
      // Fill in a random dead end.
      var deadEnd = rng.take(deadEnds);
      _carve(deadEnd, type: CellType.solid);

      removed++;
      if (max != null && removed >= max) break;

      // It may have a neighbor that's a dead end now.
      for (var dir in Direction.cardinal) {
        var neighbor = deadEnd + dir;
        if (_isDeadEnd(neighbor)) deadEnds.add(neighbor);
      }

      yield null;
    }
  }

  /// Returns `true` if the cell at [pos] is a dead end: a non-solid tiles with
  /// one non-solid neighbor.
  bool _isDeadEnd(Vec pos) {
    if (_cells[pos].isSolid) return false;

    var exits = 0;
    for (var dir in Direction.cardinal) {
      if (!_cells[pos + dir].isSolid) exits++;
    }

    return exits == 1;
  }

  void _carve(Vec pos, {CellType type = CellType.open, int? region}) {
    if (region == null) {
      if (type == CellType.open && showRegions) {
        region = _currentRegion;
      } else {
        region = Cell.noRegion;
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
        if (region != Cell.noRegion) {
          _context.fillStyle = 'hsla(${region * 17 % 360}, 80%, 20%, 0.4)'.toJS;
          _context.fillRect(
            (pos.x * cellSize + _drawOffset.x) * _pixelScale,
            (pos.y * cellSize + _drawOffset.y) * _pixelScale,
            cellSize * _pixelScale,
            cellSize * _pixelScale,
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
      Tile.image,
      tile.index * Tile.size,
      0,
      Tile.size,
      Tile.size,
      (x * cellSize + _drawOffset.x) * _pixelScale,
      (y * cellSize + _drawOffset.y) * _pixelScale,
      cellSize * _pixelScale,
      cellSize * _pixelScale,
    );
  }
}

enum Tile {
  floor,
  solid,
  wall,
  hDoor,
  vDoor,
  hConnector,
  vConnector;

  /// Size of a single tile in pixels.
  static const size = 24;

  static final image = web.HTMLImageElement()..src = "/image/2014/12/tiles.png";

  static void onLoad(Function() callback) {
    image.onLoad.listen((_) {
      callback();
    });
  }
}

enum CellType { open, solid, door }

class Cell {
  static const noRegion = -1;

  CellType type = CellType.solid;
  int region = noRegion;

  bool get isSolid => type == CellType.solid;
  bool get hasRegion => region != noRegion;
}
