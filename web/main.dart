import 'package:piecemeal/piecemeal.dart';
import 'package:rooms_and_mazes/src/dungeon.dart';

main() {
  Tile.onLoad(() {
    Dungeon("enchilada");
    RoomsDungeon();
    DeadEndsDungeon();
    MazeFillDungeon();
    ConnectorsDungeon();
    GiantDungeon();
  });
}

class RoomsDungeon extends Dungeon {
  RoomsDungeon() : super("rooms", showRegions: false) {
    slider("attempts", (value) => roomTries = value);
  }

  @override
  Iterable<void> run() => placeRooms();
}

class DeadEndsDungeon extends Dungeon {
  DeadEndsDungeon() : super("dead-ends", showRegions: false) {
    slider("dead-end-remove", (value) => cellsToRemove = value);
  }

  int cellsToRemove = 500;

  @override
  Iterable<void> run() sync* {
    for (var _ in growMaze(Vec(1, 1))) {}
    for (var _ in findConnectors()) {}
    yield* removeDeadEnds(max: cellsToRemove);
  }
}

class MazeFillDungeon extends Dungeon {
  MazeFillDungeon() : super("maze-fill", roomTries: 600);

  @override
  Iterable<void> run() sync* {
    yield* placeRooms();
    yield* placeMazes();
  }
}

class ConnectorsDungeon extends Dungeon {
  ConnectorsDungeon() : super("connectors", speed: 5);

  @override
  Iterable<void> run() sync* {
    for (var _ in placeRooms()) {}
    for (var _ in placeMazes()) {}
    yield* findConnectors(draw: true);
  }
}

class GiantDungeon extends Dungeon {
  GiantDungeon()
    : super("giant", cellSize: 2, speed: 10, roomTries: 2000, maxRoomSize: 12) {
    slider("giant-rooms", (value) => roomTries = value);
    slider("giant-room-size", (value) => maxRoomSize = value);
    slider("giant-wiggle", (value) => wigglePercent = value);
    slider("giant-speed", (value) => speed = value, reset: false);
  }
}
