// ImGuiIO can't be used from Zig: translate-c turns structs with bitfields
// opaque and that spreads to ImGuiIO. These read and write it from C instead.
#include <stdbool.h>
#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#include "cimgui.h"

void siejImguiEnableDocking(void) { igGetIO_Nil()->ConfigFlags |= ImGuiConfigFlags_DockingEnable; }
bool siejImguiWantTextInput(void) { return igGetIO_Nil()->WantTextInput; }

// rlImGui feeds mouse buttons to ImGui by polling raylib once per frame, and
// raylib only keeps the current button state: a click whose press and release
// both land within one frame (fast click, touchpad tap) is lost. Forward GLFW's
// button events to ImGui's input queue as they happen; ImGui spreads a press and
// release over separate frames and drops the duplicates rlImGui also sends.
typedef struct GLFWwindow GLFWwindow;
typedef void (*GLFWmousebuttonfun)(GLFWwindow *, int, int, int);
GLFWmousebuttonfun glfwSetMouseButtonCallback(GLFWwindow *, GLFWmousebuttonfun);
GLFWwindow *glfwGetCurrentContext(void); // raylib's window; GetWindowHandle() is the X11 id on Linux, not this

static GLFWmousebuttonfun raylib_mouse_button;

static void mouseButton(GLFWwindow *w, int button, int action, int mods) {
    if (raylib_mouse_button) raylib_mouse_button(w, button, action, mods);
    if (button < ImGuiMouseButton_COUNT) ImGuiIO_AddMouseButtonEvent(igGetIO_Nil(), button, action != 0); // GLFW_RELEASE = 0
}

void siejImguiForwardMouseButtons(void) {
    raylib_mouse_button = glfwSetMouseButtonCallback(glfwGetCurrentContext(), mouseButton);
}
