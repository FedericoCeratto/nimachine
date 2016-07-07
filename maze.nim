# Maze generator in Nimrod
# Joe Wingbermuehle 2013-10-01

import math
import random

randomize()
# Width and height must be odd.
const width = 15
const height = 15

type MazeT* = array[0 .. height - 1, array[0 .. width - 1, int]]

proc showMaze(maze: MazeT) =
   for y in countup(0, height - 1):
      for x in countup(0, width - 1):
         if maze[y][x] == 1:
            write(stdout, "#")
         else:
            write(stdout, " ")
      write(stdout, "\n")


proc initMaze(maze: ref MazeT) =
   for y in countup(0, height - 1):
      for x in countup(0, width - 1):
         maze[y][x] = 1
   for x in countup(0, width - 1):
      maze[0][x] = 0
      maze[height - 1][x] = 0
   for y in countup(0, height - 1):
      maze[y][0] = 0
      maze[y][width - 1] = 0


proc carveMaze(maze: ref MazeT, x, y: int) =
   maze[y][x] = 0
   let d = random(4)
   for i in countup(0, 3):
      var dx, dy: int
      case (d + i) mod 4
      of 0: dx = 1
      of 1: dx = -1
      of 2: dy = 1
      else: dy = -1
      let
         nx = x + dx
         ny = y + dy
         nx2 = x + 2 * dx
         ny2 = y + 2 * dy
      if maze[ny][nx] == 1 and maze[ny2][nx2] == 1:
         maze[ny][nx] = 0
         carveMaze(maze, nx2, ny2)


proc generateMaze*(): MazeT =
  var Presult: ref MazeT
  new(Presult)
  initMaze(Presult)
  carveMaze(Presult, 2, 2)
  Presult[1][2] = 0
  Presult[height - 2][width - 3] = 0
  for x in 0..width:
    for y in 0..height:
      stdout.write if Presult[y][x] == 1: "▉" else: " "
    echo " "

  return Presult[]


import basic2d,
  random
from math import Pi

type Path = seq[Vector2d]

proc shuffle[T](x: var seq[T]) =
  for i in countdown(x.high, 0):
    let j = random(i + 1)
    swap(x[i], x[j])


#const angles = @[-Pi/2, Pi/2, 0, Pi]
#
#proc step(goal: Vector2d, path: Path): bool  =
#  ## Try to reach the goal
#  var rand_angles = angles
#  rand_angles.shuffle()
#  for angle in rand_angles:
#    let p2 = path[path.high-1]
#    let p = path[path.high]
#    let c = p + 
#    echo angle

