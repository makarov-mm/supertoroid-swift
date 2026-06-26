// main.swift
// Supertoroid renderer — Swift, AppKit (NSOpenGLView), OpenGL 4.1 core
// Port of the Win32/WGL/OpenGL 4.3 C++ version.
//
// Build (single file, no project needed):
//   swiftc main.swift -o supertoroid -framework Cocoa -framework OpenGL
//   ./supertoroid
//
// To silence the OpenGL deprecation warnings during build:
//   swiftc main.swift -o supertoroid -framework Cocoa -framework OpenGL -suppress-warnings
//
// Controls:
//   Mouse drag    — rotate
//   Scroll        — zoom
//   N / M         — decrease / increase exponent n
//   T / Y         — decrease / increase twist
//   R             — reset
//   F             — toggle fullscreen
//   ESC           — quit
//
// Note: Apple deprecated OpenGL in macOS 10.14, but it still compiles and runs
// (tested target: macOS 10.14+). Max desktop GL on macOS is 4.1, hence #version 410 core.

import Cocoa
import OpenGL.GL3

// ============================================================
// MARK: - Math (column-major 4x4, identical convention to the C++ version)
// ============================================================

struct Mat4 {
    var m = [Float](repeating: 0, count: 16)

    static func identity() -> Mat4 {
        var r = Mat4()
        r.m[0] = 1; r.m[5] = 1; r.m[10] = 1; r.m[15] = 1
        return r
    }
}

// Standard column-major multiply: result = a * b
// (used as M*v in the shader => b is applied first, then a)
func mat4Mul(_ a: Mat4, _ b: Mat4) -> Mat4 {
    var r = Mat4()
    for col in 0..<4 {
        for row in 0..<4 {
            var s: Float = 0
            for k in 0..<4 { s += a.m[k * 4 + row] * b.m[col * 4 + k] }
            r.m[col * 4 + row] = s
        }
    }
    return r
}

func mat4Perspective(_ fovY: Float, _ aspect: Float, _ zNear: Float, _ zFar: Float) -> Mat4 {
    let f = 1.0 / tanf(fovY * 0.5)
    var r = Mat4()
    r.m[0]  = f / aspect
    r.m[5]  = f
    r.m[10] = (zFar + zNear) / (zNear - zFar)
    r.m[11] = -1.0
    r.m[14] = (2.0 * zFar * zNear) / (zNear - zFar)
    return r
}

func mat4RotX(_ a: Float) -> Mat4 {
    var r = Mat4.identity()
    r.m[5] = cosf(a);  r.m[6]  = sinf(a)
    r.m[9] = -sinf(a); r.m[10] = cosf(a)
    return r
}

func mat4RotY(_ a: Float) -> Mat4 {
    var r = Mat4.identity()
    r.m[0] = cosf(a); r.m[2]  = -sinf(a)
    r.m[8] = sinf(a); r.m[10] = cosf(a)
    return r
}

func mat4Translate(_ x: Float, _ y: Float, _ z: Float) -> Mat4 {
    var r = Mat4.identity()
    r.m[12] = x; r.m[13] = y; r.m[14] = z
    return r
}

// ============================================================
// MARK: - Supertoroid mesh (interleaved: pos3, normal3, uv2)
// ============================================================

func buildSupertoroid(n: Float, twist: Float, a: Float, Nu: Int, Nv: Int)
    -> (verts: [Float], indices: [UInt32])
{
    var verts = [Float]()
    verts.reserveCapacity((Nu + 1) * (Nv + 1) * 8)
    var indices = [UInt32]()
    indices.reserveCapacity(Nu * Nv * 6)

    let invN: Float = 1.0 / n
    let pi2: Float = 2.0 * Float.pi

    func pos(_ u: Float, _ v: Float) -> (Float, Float, Float) {
        var cv = abs(cosf(v)); if cv < 1e-9 { cv = 1e-9 }
        var sv = abs(sinf(v)); if sv < 1e-9 { sv = 1e-9 }
        let R = powf(powf(cv, n) + powf(sv, n), -invN)
        let phi = twist * u + v
        let r = a + R * cosf(phi)
        return (r * cosf(u), r * sinf(u), R * sinf(phi))
    }

    // Vertices
    for iv in 0...Nv {
        let vp = pi2 * Float(iv) / Float(Nv)
        for iu in 0...Nu {
            let up = pi2 * Float(iu) / Float(Nu)
            let p = pos(up, vp)

            // Numerical normal via central finite difference
            let eps: Float = 1e-4
            let pu1 = pos(up + eps, vp), pu0 = pos(up - eps, vp)
            let pv1 = pos(up, vp + eps), pv0 = pos(up, vp - eps)

            let dux = (pu1.0 - pu0.0) / (2 * eps)
            let duy = (pu1.1 - pu0.1) / (2 * eps)
            let duz = (pu1.2 - pu0.2) / (2 * eps)
            let dvx = (pv1.0 - pv0.0) / (2 * eps)
            let dvy = (pv1.1 - pv0.1) / (2 * eps)
            let dvz = (pv1.2 - pv0.2) / (2 * eps)

            var nx = duy * dvz - duz * dvy
            var ny = duz * dvx - dux * dvz
            var nz = dux * dvy - duy * dvx
            var nl = sqrtf(nx * nx + ny * ny + nz * nz)
            if nl < 1e-9 { nl = 1 }
            nx /= nl; ny /= nl; nz /= nl

            verts.append(contentsOf: [
                p.0, p.1, p.2,
                nx, ny, nz,
                Float(iu) / Float(Nu), Float(iv) / Float(Nv)
            ])
        }
    }

    // Indices — CCW winding so front faces match the outward normals
    for iv in 0..<Nv {
        for iu in 0..<Nu {
            let i0 = UInt32(iv * (Nu + 1) + iu)
            let i1 = i0 + 1
            let i2 = i0 + UInt32(Nu + 1)
            let i3 = i2 + 1
            indices.append(contentsOf: [i0, i1, i2,  i1, i3, i2])
        }
    }

    return (verts, indices)
}

// ============================================================
// MARK: - Shaders (GLSL 410 core)
// ============================================================

let vsSource = """
#version 410 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNorm;
layout(location = 2) in vec2 aUV;

uniform mat4 uMVP;
uniform mat4 uModel;
uniform mat4 uNormalMat;

out vec3 vNormal;
out vec3 vWorldPos;
out vec2 vUV;

void main() {
    vNormal   = normalize((uNormalMat * vec4(aNorm, 0.0)).xyz);
    vWorldPos = (uModel * vec4(aPos, 1.0)).xyz;
    vUV       = aUV;
    gl_Position = uMVP * vec4(aPos, 1.0);
}
"""

let fsSource = """
#version 410 core
in vec3 vNormal;
in vec3 vWorldPos;
in vec2 vUV;

uniform vec3 uLightDir;
uniform float uTime;

out vec4 fragColor;

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main() {
    vec3 N = normalize(vNormal);
    vec3 L = normalize(uLightDir);
    vec3 V = normalize(-vWorldPos);
    vec3 H = normalize(L + V);

    float hue = fract(vUV.x + vUV.y * 0.3 + uTime * 0.08);
    vec3 baseColor = hsv2rgb(vec3(hue, 0.75, 1.0));

    float ambient  = 0.12;
    float diffuse  = max(dot(N, L), 0.0) * 0.65;
    float specular = pow(max(dot(N, H), 0.0), 64.0) * 0.6;
    float rim      = pow(1.0 - max(dot(N, V), 0.0), 3.0) * 0.3;

    vec3 col = baseColor * (ambient + diffuse) + vec3(1.0) * specular + baseColor * rim;

    float grid = smoothstep(0.96, 1.0, max(
        abs(sin(vUV.x * 3.14159 * 48.0)),
        abs(sin(vUV.y * 3.14159 * 48.0))
    ));
    col = mix(col, col * 0.35, grid * 0.6);

    fragColor = vec4(col, 1.0);
}
"""

// ============================================================
// MARK: - GL helpers
// ============================================================

func compileShader(_ type: GLenum, _ src: String) -> GLuint {
    let shader = glCreateShader(type)
    src.withCString { cs in
        var p: UnsafePointer<GLchar>? = cs
        glShaderSource(shader, 1, &p, nil)
    }
    glCompileShader(shader)

    var ok: GLint = 0
    glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &ok)
    if ok == 0 {
        var len: GLint = 0
        glGetShaderiv(shader, GLenum(GL_INFO_LOG_LENGTH), &len)
        var log = [GLchar](repeating: 0, count: Int(max(len, 1)))
        glGetShaderInfoLog(shader, GLsizei(log.count), nil, &log)
        FileHandle.standardError.write("Shader compile error: \(String(cString: log))\n".data(using: .utf8)!)
    }
    return shader
}

func buildProgram(_ vs: String, _ fs: String) -> GLuint {
    let v = compileShader(GLenum(GL_VERTEX_SHADER), vs)
    let f = compileShader(GLenum(GL_FRAGMENT_SHADER), fs)
    let p = glCreateProgram()
    glAttachShader(p, v)
    glAttachShader(p, f)
    glLinkProgram(p)

    var ok: GLint = 0
    glGetProgramiv(p, GLenum(GL_LINK_STATUS), &ok)
    if ok == 0 {
        var len: GLint = 0
        glGetProgramiv(p, GLenum(GL_INFO_LOG_LENGTH), &len)
        var log = [GLchar](repeating: 0, count: Int(max(len, 1)))
        glGetProgramInfoLog(p, GLsizei(log.count), nil, &log)
        FileHandle.standardError.write("Program link error: \(String(cString: log))\n".data(using: .utf8)!)
    }
    glDeleteShader(v)
    glDeleteShader(f)
    return p
}

// ============================================================
// MARK: - View
// ============================================================

func makeToroidPixelFormat() -> NSOpenGLPixelFormat? {
    let attrs: [NSOpenGLPixelFormatAttribute] = [
        NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
        NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion4_1Core),
        NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 24,
        NSOpenGLPixelFormatAttribute(NSOpenGLPFAAlphaSize), 8,
        NSOpenGLPixelFormatAttribute(NSOpenGLPFADepthSize), 24,   // important: real depth buffer
        NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
        NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
        0
    ]
    return NSOpenGLPixelFormat(attributes: attrs)
}

final class ToroidView: NSOpenGLView {

    var prog: GLuint = 0
    var vao: GLuint = 0, vbo: GLuint = 0, ebo: GLuint = 0
    var indexCount: GLsizei = 0

    var locMVP: GLint = -1, locModel: GLint = -1, locNorm: GLint = -1
    var locLight: GLint = -1, locTime: GLint = -1

    // Camera
    var rotX: Float = 0.3, rotY: Float = 0.5, zoom: Float = 11.0
    var dragging = false
    var lastMouse = NSPoint.zero

    // Supertoroid params
    var n: Float = 4.0, twist: Float = 2.0, a: Float = 3.5
    let Nu = 256, Nv = 128

    var timeVal: Float = 0
    var lastTime = ProcessInfo.processInfo.systemUptime

    override var acceptsFirstResponder: Bool { true }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        wantsBestResolutionOpenGLSurface = true
        openGLContext?.makeCurrentContext()

        var swap: GLint = 1
        openGLContext?.setValues(&swap, for: .swapInterval)

        prog     = buildProgram(vsSource, fsSource)
        locMVP   = glGetUniformLocation(prog, "uMVP")
        locModel = glGetUniformLocation(prog, "uModel")
        locNorm  = glGetUniformLocation(prog, "uNormalMat")
        locLight = glGetUniformLocation(prog, "uLightDir")
        locTime  = glGetUniformLocation(prog, "uTime")

        glGenVertexArrays(1, &vao)
        glGenBuffers(1, &vbo)
        glGenBuffers(1, &ebo)
        uploadMesh()

        glEnable(GLenum(GL_DEPTH_TEST))
        glEnable(GLenum(GL_CULL_FACE))
        glCullFace(GLenum(GL_BACK))
        glClearColor(0.04, 0.04, 0.06, 1.0)
    }

    func uploadMesh() {
        openGLContext?.makeCurrentContext()
        let (verts, indices) = buildSupertoroid(n: n, twist: twist, a: a, Nu: Nu, Nv: Nv)
        indexCount = GLsizei(indices.count)

        let fsz = MemoryLayout<Float>.size
        let stride = GLsizei(fsz * 8)

        glBindVertexArray(vao)

        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
        glBufferData(GLenum(GL_ARRAY_BUFFER), verts.count * fsz, verts, GLenum(GL_STATIC_DRAW))

        glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), ebo)
        glBufferData(GLenum(GL_ELEMENT_ARRAY_BUFFER),
                     indices.count * MemoryLayout<UInt32>.size, indices, GLenum(GL_STATIC_DRAW))

        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 3, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride,
                              UnsafeRawPointer(bitPattern: 0))
        glEnableVertexAttribArray(1)
        glVertexAttribPointer(1, 3, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride,
                              UnsafeRawPointer(bitPattern: 3 * fsz))
        glEnableVertexAttribArray(2)
        glVertexAttribPointer(2, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride,
                              UnsafeRawPointer(bitPattern: 6 * fsz))

        glBindVertexArray(0)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = openGLContext else { return }
        ctx.makeCurrentContext()

        let now = ProcessInfo.processInfo.systemUptime
        var dt = Float(now - lastTime)
        lastTime = now
        if dt > 0.05 { dt = 0.05 }
        timeVal += dt

        let backing = convertToBacking(bounds.size)
        let w = GLsizei(max(backing.width, 1))
        let h = GLsizei(max(backing.height, 1))
        glViewport(0, 0, w, h)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT) | GLbitfield(GL_DEPTH_BUFFER_BIT))

        let aspect = Float(backing.width) / Float(max(backing.height, 1))
        let proj  = mat4Perspective(0.8, aspect, 0.1, 200.0)
        let view  = mat4Translate(0, 0, -zoom)
        let model = mat4Mul(mat4RotX(rotX), mat4RotY(rotY))
        let mvp   = mat4Mul(proj, mat4Mul(view, model))

        glUseProgram(prog)
        glUniformMatrix4fv(locMVP,   1, GLboolean(GL_FALSE), mvp.m)
        glUniformMatrix4fv(locModel, 1, GLboolean(GL_FALSE), model.m)
        glUniformMatrix4fv(locNorm,  1, GLboolean(GL_FALSE), model.m)
        glUniform3f(locLight, 0.6, 1.0, 0.8)
        glUniform1f(locTime, timeVal)

        glBindVertexArray(vao)
        glDrawElements(GLenum(GL_TRIANGLES), indexCount, GLenum(GL_UNSIGNED_INT), nil)
        glBindVertexArray(0)

        ctx.flushBuffer()
    }

    // ---- Input ----

    override func mouseDown(with event: NSEvent) {
        dragging = true
        lastMouse = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let p = event.locationInWindow
        let dx = Float(p.x - lastMouse.x)
        let dy = Float(p.y - lastMouse.y)
        rotY += dx * 0.008
        rotX -= dy * 0.008   // macOS y axis points up
        lastMouse = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    override func scrollWheel(with event: NSEvent) {
        zoom -= Float(event.scrollingDeltaY) * 0.02
        if zoom < 1.5 { zoom = 1.5 }
        if zoom > 30.0 { zoom = 30.0 }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let ch = event.charactersIgnoringModifiers?.lowercased().first else { return }
        switch ch {
        case "\u{1b}": NSApp.terminate(nil)                                   // ESC
        case "n": n = max(2.1, n - 0.5); uploadMesh(); updateTitle()
        case "m": n = min(16.0, n + 0.5); uploadMesh(); updateTitle()
        case "t": twist = max(1.0, twist - 1.0); uploadMesh(); updateTitle()
        case "y": twist = min(8.0, twist + 1.0); uploadMesh(); updateTitle()
        case "r":
            n = 4.0; twist = 2.0; rotX = 0.3; rotY = 0.5; zoom = 11.0
            uploadMesh(); updateTitle()
        case "f": window?.toggleFullScreen(nil)
        default: break
        }
        needsDisplay = true
    }

    func updateTitle() {
        window?.title = String(format:
            "Supertoroid  |  n=%.1f  twist=%.1f  |  N/M: n  T/Y: twist  R: reset  F: fullscreen  ESC: quit",
            n, twist)
    }
}

// ============================================================
// MARK: - Application entry point
// ============================================================

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var view: ToroidView!
    var timer: Timer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: style, backing: .buffered, defer: false)
        window.center()
        window.title = "Supertoroid"
        window.delegate = self

        guard let pf = makeToroidPixelFormat() else {
            FileHandle.standardError.write("Failed to create an OpenGL 4.1 core pixel format.\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        guard let v = ToroidView(frame: window.contentView!.bounds, pixelFormat: pf) else {
            FileHandle.standardError.write("Failed to create the OpenGL view.\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        view = v
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        view.updateTitle()

        // ~60 fps redraw
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak view] _ in
            view?.needsDisplay = true
        }
        RunLoop.current.add(timer, forMode: .common)

        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()