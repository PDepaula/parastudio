# Diagnostic for .github/workflows/platform-check.yml: why can (or can't) this
# runner open a GL window? Prints GLFW's own error text for each attempt:
# a hidden GL 3.3 core window (what `paraloop/app.createWindow` asks for), a
# visible one, and a default-hint window. Build: nim c --hints:off -r this file.
import paranim/glfw
when not defined(windows):
  {.passL: "-lm".} # the bundled GLFW needs libm; a game links it through another module

proc onError(code: int32, desc: cstring) {.cdecl.} =
  echo "  glfw error ", code, ": ", desc

proc attempt(name: string, core, visible: bool) =
  glfwDefaultWindowHints()
  if core:
    glfwWindowHint(GLFWContextVersionMajor, 3)
    glfwWindowHint(GLFWContextVersionMinor, 3)
    glfwWindowHint(GLFWOpenglForwardCompat, GLFWTrue)
    glfwWindowHint(GLFWOpenglProfile, GLFWOpenglCoreProfile)
  if not visible: glfwWindowHint(GLFWVisible, GLFWFalse)
  let w = glfwCreateWindow(320, 240, "probe", icon = false)
  if w == nil:
    echo name, ": FAILED"
  else:
    w.makeContextCurrent()
    echo name, ": ok"
    w.destroyWindow()

discard glfwSetErrorCallback(onError)
if not glfwInit():
  echo "glfwInit: FAILED"
else:
  echo "glfwInit: ok"
  attempt("hidden GL3.3 core", true, false)
  attempt("visible GL3.3 core", true, true)
  attempt("hidden default hints", false, false)
  glfwTerminate()
