This is the code for the animated demos of the random dungeon generation
algorithm described by [this blog post][post].

You're welcome to play with this code, but it's actually not the best reference
for the dungeon generator. Slicing it up into animated form adds a ton of
complexity, and I kind of hacked this together with little regard for good
software engineering. If you'd like a cleaner implementation, take a look at
[how I implemented it][algo] in my roguelike [Hauberk][]. It's a nice, tight
300 lines of clean code there.

[post]: http://journal.stuffwithstuff.com/2014/12/21/rooms-and-mazes
[algo]: https://github.com/munificent/hauberk/blob/db360d9efa714efb6d937c31953ef849c7394a39/lib/src/content/dungeon.dart
[hauberk]: https://github.com/munificent/hauberk
