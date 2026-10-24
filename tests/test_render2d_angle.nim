## `render2d`'s `angle` is the screen angle of the +x edge on the y-down canvas
## (clockwise-positive), so `arctan2(dy, dx)` of a screen vector draws along it.
## Headless: runs the real `placeRotated` (what `addRegion`/`addRect` apply) on
## an uncompiled entity and applies its matrix the way the instanced shader
## does -- paranim flattens the glm matrix row-major into `a_matrix`, which
## GLSL reads as columns, i.e. the shader applies the transpose.
import std/[unittest, math]
import paranim/opengl
import paranim/gl, paranim/gl/entities
import paranim/glm
from paranim/primitives import nil
import paraloop/render2d

proc shaderApply(m: Mat3x3[GLfloat], x, y: float): (float, float) =
  let t = m.transpose()
  let v = t * vec3(GLfloat x, GLfloat y, 1f)
  (float v[0], float v[1])

proc place(cx, cy, w, h, angle: float): Mat3x3[GLfloat] =
  var e = initTwoDEntity(primitives.rectangle[GLfloat]())
  e.placeRotated(cx, cy, w, h, angle)
  e.uniforms.u_matrix.data

suite "render2d angle":
  test "+x edge midpoint lands along arctan2(dy, dx) of the angle":
    let (cx, cy, w, h) = (300.0, 200.0, 80.0, 36.0)
    for angle in [PI / 4, -PI / 4, PI / 2, -PI / 2, 0.0, PI]:
      let m = place(cx, cy, w, h, angle)
      # unit quad +x edge midpoint is (1, 0.5)
      let (x, y) = shaderApply(m, 1.0, 0.5)
      check abs(x - (cx + cos(angle) * w / 2)) < 1e-3
      check abs(y - (cy + sin(angle) * w / 2)) < 1e-3

  test "quad centre stays put":
    let m = place(300.0, 200.0, 80.0, 36.0, 1.1)
    let (x, y) = shaderApply(m, 0.5, 0.5)
    check abs(x - 300.0) < 1e-3
    check abs(y - 200.0) < 1e-3
