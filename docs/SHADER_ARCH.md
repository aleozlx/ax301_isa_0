# Shader Architecture & Performance Analysis

## Overview

This document analyzes the performance characteristics and architectural trade-offs for implementing a multi-core shader pipeline on the FPGA soft processor. The target is real-time graphics rendering (15-30 fps) with procedural/vector graphics capabilities.

---

## Performance Budget Analysis

### Base Configuration: 1024×768 Resolution

**Pixel throughput requirements:**

| Target FPS | Frame time | Pixels/frame | Time/pixel | Notes |
|------------|-----------|--------------|------------|-------|
| 30 fps | 33.33 ms | 786,432 | 42.37 ns | Very tight |
| 15 fps | 66.67 ms | 786,432 | 84.74 ns | Feasible |

**Clock cycles available per pixel:**

| Config | Clock | Cores | FPS | Cycles/pixel/core | Feasibility |
|--------|-------|-------|-----|-------------------|-------------|
| Base | 100MHz | 1 | 30 | 4.2 | ❌ Impossible (SDRAM = 10-20 cycles) |
| Dual | 100MHz | 2 | 30 | 8.4 | ❌ Still too tight |
| Quad | 100MHz | 4 | 30 | 16.8 | ⚠️ Barely feasible |
| Quad | 100MHz | 4 | 15 | **34 cycles** | ✅ Workable |
| Quad | 125MHz | 4 | 15 | **42 cycles** | ✅ Comfortable |

**SDRAM timing constraints (H57V2562):**
- Single read: 15-20 cycles @ 100MHz
- Burst read (256 words): ~15-20 cycles amortized per word
- Maximum safe frequency: **125MHz** (T_RP/T_RCD still met)

---

## Recommended Configuration: 800×600 Resolution

**Benefits of SVGA (800×600) over XGA (1024×768):**
- **39% fewer pixels** (480,000 vs 786,432)
- Standard VESA timing (40MHz pixel clock)
- 38% smaller framebuffer (938 KiB vs 1.5 MiB per buffer)
- More memory available for textures/assets

**Performance budget @ 800×600:**

| Config | Clock | Cores | FPS | Cycles/pixel | Capabilities |
|--------|-------|-------|-----|--------------|--------------|
| Baseline | 100MHz | 4 | 15 | **56 cycles** | Single texture + lighting |
| Optimal | 125MHz | 4 | 15 | **69 cycles** | Multi-texture + effects |
| Fast | 125MHz | 4 | 30 | 35 cycles | Simple shading |

**Memory bandwidth utilization @ 800×600, 15fps:**
- Pixel writes: 480,000 × 15 × 2 bytes = 14.4 MB/s
- Texture reads (2× per pixel): 28.8 MB/s
- **Total: 43.2 MB/s** (22% of 200 MB/s SDRAM bandwidth @ 100MHz)
- **Plenty of headroom!**

---

## Shader Core Resource Estimates

### Per-Core Logic Elements (LEs)

Based on current single-core implementation (1,443 LEs total):

| Component | LEs per core | Notes |
|-----------|-------------|-------|
| Register file (16×16-bit) | 50 | Flip-flops |
| Instruction decoder | 50 | Combinatorial |
| ALU (ADD, XOR, AND, OR, SHL, SHR) | 150 | |
| State machine (FSM) | 100 | FETCH, EXEC, MEM_WAIT |
| Stack pointer + control | 50 | |
| SDRAM arbiter overhead | 50 | Multiplexing |
| **Total per core** | **~450 LEs** | |

**Shared infrastructure (amortized):**
- SDRAM controller: 800 LEs (shared by all cores)
- VGA timing + line buffer FSM: 300 LEs
- UART RX: 200 LEs
- 7-segment display: 300 LEs
- Monitor FSM: 100 LEs

### Scaling Analysis (6,272 LEs available)

| Core count | Core LEs | Shared LEs | Total LEs | Utilization | Feasible? |
|------------|----------|------------|-----------|-------------|-----------|
| 1 | 450 | 1,043 | 1,493 | 24% | ✅ Current |
| 2 | 900 | 1,093 | 1,993 | 32% | ✅ Easy |
| 4 | 1,800 | 1,193 | 2,993 | 48% | ✅ **Recommended** |
| 8 | 3,600 | 1,393 | 4,993 | 80% | ✅ Tight but achievable |
| 16 | 7,200 | 1,793 | 8,993 | 143% | ❌ Won't fit |

**Block RAM requirements (34 KiB total available):**

| Component | Per core | 4 cores | 8 cores |
|-----------|----------|---------|---------|
| Register file (16×16-bit) | 256 bits | 1 KiB | 2 KiB |
| Constant stack (64 entries) | 1 KiB | 4 KiB | 8 KiB |
| VGA line buffers (800×600) | - | 3.2 KiB | 3.2 KiB |
| **Total** | - | **8.2 KiB (24%)** | **13.2 KiB (39%)** |

**Recommendation: 4 shader cores @ 48% LE utilization**
- Comfortable routing headroom
- 10+ KiB Block RAM free for texture cache
- Scalable to 8 cores if needed

---

## Optimization Strategies

### Strategy 1: Temporal Resolution Scaling

Alternate between low-resolution shading and full-resolution frames.

#### Checkerboard Rendering (50% pixels per frame)

```
Frame 0:  X . X . X .    Frame 1:  . X . X . X
          . X . X . X              X . X . X .
          X . X . X .              . X . X . X
```

**Benefits:**
- Effective pixels: 240,000 per frame (50% reduction)
- **Cycles per pixel: 138 cycles** @ 125MHz, 4 cores, 15fps
- Or achieve **30fps** at original 69-cycle budget
- Simple bilinear reconstruction from neighbors

#### Quarter-Resolution Shading (400×300 → 800×600)

**Resolution comparison:**

| Mode | Pixels | Cycles/pixel (125MHz, 4 cores, 15fps) | FPS achievable |
|------|--------|---------------------------------------|----------------|
| Full (800×600) | 480,000 | 69 cycles | 15 fps |
| Quarter (400×300) | 120,000 | **277 cycles** | **60 fps!** |

**Implementation:**
- Shade at 400×300 resolution
- Hardware bilinear upscaler (100-150 LEs)
- 2× faster framerate OR 4× shader complexity

**Bilinear upscaler (simplified):**
```verilog
wire [9:0] src_x = display_x >> 1;
wire [9:0] src_y = display_y >> 1;
wire frac_x = display_x[0];
wire frac_y = display_y[0];

// Fetch 2×2 neighborhood, interpolate
pixel_out = (tl * ~frac_x * ~frac_y +
             tr * frac_x  * ~frac_y +
             bl * ~frac_x * frac_y  +
             br * frac_x  * frac_y) >> 2;
```

#### Adaptive Temporal Scheduling

**5-frame cycle example:**
```
Frame 0: Full 800×600 shade (reference frame)     → 66.67 ms
Frame 1: Quarter 400×300 + upscale                → 16.67 ms
Frame 2: Quarter 400×300 + upscale                → 16.67 ms
Frame 3: Quarter 400×300 + upscale                → 16.67 ms
Frame 4: Half-res checkerboard                    → 33.33 ms
Repeat...
```

**Temporal Anti-Aliasing (TAA):**
- Accumulate 4 quarter-res frames
- Supersampling effect with sample jittering
- Motion blur / cinematic feel
- **Perceived quality: ~90% of full resolution**

---

### Strategy 2: Hierarchical / Foveated Rendering

Shade different screen regions at different resolutions based on importance.

**Example spatial allocation:**

```
800×600 screen divided into regions:

Center (256×200):     Full resolution (player focus area)
Mid ring (544×400):   Half resolution (2×2 pixel blocks)
Edges (800×600):      Quarter resolution (4×4 blocks)
```

**Pixel counts:**
- Center: 51,200 pixels (full shading)
- Mid ring: 166,400 / 4 = 41,600 pixels (half-res)
- Edges: 262,400 / 16 = 16,400 pixels (quarter-res)
- **Total shaded: 109,200 pixels (23% of full frame!)**

**Budget @ 125MHz, 4 cores, 30fps:**
- Time available: 33.33 ms
- Time per pixel: 33.33 ms / 109,200 = 305 ns
- **Cycles per pixel: 76 cycles**
- Center region gets full detail, edges save bandwidth

---

## Procedural / Vector Graphics Pipeline

### Architecture Overview

**Key insight:** For geometric primitives (circles, rectangles, text), process the *primitive* once, then rasterize only pixels inside its bounding box.

**Two-stage pipeline:**

```
┌──────────────────┐
│ Primitive Buffer │ (SDRAM: geometric data)
│ - 100 circles    │ Circle: {center_x, center_y, radius, color}
│ - 50 rectangles  │ Rect:   {x, y, width, height, color}
│ - 20 text glyphs │ Glyph:  {char_id, x, y, color}
└────────┬─────────┘
         ▼
┌──────────────────┐
│ Geometry Shader  │ (Core 0: process primitives)
│ - Bbox compute   │ → Compute bounding box for each primitive
│ - Culling        │ → Discard off-screen primitives
│ - Z-sort         │ → Order back-to-front
└────────┬─────────┘
         ▼
┌──────────────────┐
│   Rasterizer     │ (Hardware: ~200 LEs)
│ - Scanline gen   │ → Generate (x, y) coords within bbox
│ - Work dispatch  │ → Send pixel coords to fragment shaders
└────────┬─────────┘
         ▼
┌──────────────────┐
│ Fragment Shaders │ (Cores 1-4: parallel shading)
│ - Distance eval  │ → Compute distance to primitive
│ - Color compute  │ → Evaluate fill/stroke
│ - Blending       │ → Alpha composite
└────────┬─────────┘
         ▼
┌──────────────────┐
│  Framebuffer     │ (SDRAM: 800×600 RGB565)
└──────────────────┘
```

### Performance Advantages

**Example: Render 50 circles on 800×600 screen**

**Traditional texture-based approach:**
- Must scan all 480,000 pixels
- Shader invocations: **480,000**
- Texture reads: 480,000 × 2 bytes = 960 KB

**Procedural approach:**
- Geometry pass: 50 circles × 15 cycles = 750 cycles
- Fragment pass: 50 circles × ~100 pixels (avg bbox) = **5,000 shader invocations**
- Primitive data: 50 × 12 bytes = 600 bytes
- **96% fewer shader invocations, 1600× less memory!**

**Bandwidth comparison:**

| Approach | Primitive data | Texture reads | FB writes | Total/frame |
|----------|---------------|---------------|-----------|-------------|
| Texture-based | 0 | 960 KB | 960 KB | 1.92 MB |
| Procedural | 0.6 KB | 0 | 10 KB | **10.6 KB** |

---

### Geometry Shader Example: Circle

**Primitive data structure (6 words):**
```
Circle {
  center_x:      16-bit
  center_y:      16-bit
  radius:        16-bit
  fill_color:    16-bit RGB565
  stroke_color:  16-bit RGB565
  stroke_width:  16-bit
}
```

**Geometry shader (runs once per primitive):**
```assembly
geom_circle:
    LDC  prim_ptr         ; Load primitive pointer (1 cycle)
    LDCS r0               ; (1 cycle)

    ; Load circle parameters
    LOAD r1, [r0]         ; center_x (15-20 cycles SDRAM)
    LOAD r2, [r0+1]       ; center_y (cached, 1 cycle)
    LOAD r3, [r0+2]       ; radius (cached, 1 cycle)

    ; Compute bounding box
    SUB  r4, r1, r3       ; bbox_min_x = center_x - radius (1 cycle)
    ADD  r5, r1, r3       ; bbox_max_x = center_x + radius (1 cycle)
    SUB  r6, r2, r3       ; bbox_min_y = center_y - radius (1 cycle)
    ADD  r7, r2, r3       ; bbox_max_y = center_y + radius (1 cycle)

    ; Store bbox in rasterizer work queue (hardware registers)
    ; Rasterizer reads r4-r7 automatically
    RET

; Total: ~25-30 cycles per circle (once, not per pixel!)
```

### Fragment Shader Example: Circle with SDF

**Fragment shader (runs per pixel in bounding box):**
```assembly
frag_circle:
    ; r1 = pixel_x, r2 = pixel_y (hardware-mapped, read-only)

    ; Load circle parameters from constant pool
    LDC  circle_data      ; (1 cycle, cached)
    LDCS r10              ; (1 cycle)
    LOAD r3, [r10]        ; center_x (15-20 cycles)
    LOAD r4, [r10+1]      ; center_y (1 cycle, burst)
    LOAD r5, [r10+2]      ; radius (1 cycle, burst)

    ; Compute distance from center
    SUB  r6, r1, r3       ; dx = pixel_x - center_x (1 cycle)
    SUB  r7, r2, r4       ; dy = pixel_y - center_y (1 cycle)
    MUL  r6, r6           ; dx² (1 cycle if ALU has MUL)
    MUL  r7, r7           ; dy² (1 cycle)
    ADD  r8, r6, r7       ; dist² = dx² + dy² (1 cycle)

    ; Compare with radius²
    MUL  r9, r5, r5       ; radius² (1 cycle)
    CMP  r8, r9           ; dist² <=> radius² (1 cycle, sets flags)

    JLT  inside           ; if dist² < radius², fill (1 cycle)
    JMP  outside          ; else transparent (1 cycle)

inside:
    LOAD r0, [r10+3]      ; fill_color (1 cycle, burst)
    RET                   ; Write r0 to framebuffer

outside:
    MOV  r0, 0x0000       ; Transparent/background (1 cycle)
    RET

; Total: ~28-33 cycles per pixel (only inside bounding box!)
```

**Anti-aliased SDF variant (add 5-8 cycles):**
```assembly
    ; ... compute dist² ...
    SQRT r8               ; dist = sqrt(dist²) (requires SQRT unit, ~5 cycles)
    SUB  r8, r8, r5       ; signed_dist = dist - radius

    ; Smooth edge (1-pixel gradient)
    ; Alpha = saturate(0.5 - signed_dist)
    NEG  r8
    ADDI r8, 8            ; Fixed-point offset
    SHR  r8, 4            ; Normalize to 0-15 alpha range

    LOAD r9, [r10+3]      ; fill_color
    MUL  r9, r8           ; Modulate by alpha (edge smoothing)
    MOV  r0, r9
    RET
```

---

### Primitive Library

**Implementable primitives and their costs:**

| Primitive | Geometry data | Fragment cycles | Use case |
|-----------|---------------|----------------|----------|
| **Circle** | 6 words | 28-33 | Buttons, icons, particles |
| **Rectangle** | 5 words (x, y, w, h, color) | 10-15 | UI panels, bars |
| **Rounded rect** | 7 words (+ corner radius) | 40-50 | Modern UI elements |
| **Line** | 6 words (x0, y0, x1, y1, width, color) | 35-40 | Graphs, wireframes |
| **Linear gradient** | 6 words (x0, y0, x1, y1, color0, color1) | 20-25 | Backgrounds, shading |
| **Bezier curve** | 8 words (4 control points) | 60-80 | Smooth curves |
| **Text glyph** | 4 words (char_id, x, y, color) + SDF atlas | 30-40 | High-quality text |

---

### Rasterizer Hardware Module

**Purpose:** Generate pixel coordinates within bounding box, feed to shader cores.

```verilog
module rasterizer(
    input clk,
    input rst_n,

    // Bounding box from geometry shader
    input [15:0] bbox_min_x,
    input [15:0] bbox_min_y,
    input [15:0] bbox_max_x,
    input [15:0] bbox_max_y,
    input start,

    // Pixel stream output to fragment shaders
    output reg [9:0] pixel_x,
    output reg [9:0] pixel_y,
    output reg pixel_valid,
    output reg done
);

reg [9:0] scan_x, scan_y;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scan_x <= 10'd0;
        scan_y <= 10'd0;
        pixel_valid <= 1'b0;
        done <= 1'b0;
    end else if (start) begin
        // Initialize scanline at top-left of bbox
        scan_x <= bbox_min_x[9:0];
        scan_y <= bbox_min_y[9:0];
        pixel_valid <= 1'b1;
        done <= 1'b0;
    end else if (pixel_valid) begin
        // Scan left-to-right, top-to-bottom
        if (scan_x < bbox_max_x[9:0]) begin
            scan_x <= scan_x + 1;
        end else begin
            scan_x <= bbox_min_x[9:0];
            if (scan_y < bbox_max_y[9:0]) begin
                scan_y <= scan_y + 1;
            end else begin
                pixel_valid <= 1'b0;
                done <= 1'b1;
            end
        end

        pixel_x <= scan_x;
        pixel_y <= scan_y;
    end else if (done) begin
        done <= 1'b0;  // Clear done flag
    end
end

endmodule
```

**Resource cost:** ~200 LEs (counters + comparators)

---

### Performance Estimate: Procedural Scene

**Scene: 100 geometric primitives @ 800×600, 30fps**

**Geometry pass (Core 0):**
- 100 primitives × 30 cycles average = 3,000 cycles
- @ 125MHz: **24 microseconds**

**Fragment pass (Cores 1-4, parallel):**
- Assume 50,000 total pixel coverage (tight bboxes)
- 50,000 pixels ÷ 4 cores = 12,500 pixels per core
- @ 30 cycles per pixel: 375,000 cycles per core
- @ 125MHz: **3 milliseconds per core**

**Total frame time: 3.024 ms**
- Target for 30fps: 33.33 ms
- **Margin: 11× faster than required!**

**Scaling potential:**
- Could render **1,100 primitives** at 30fps
- Or use **300-cycle complex shaders**
- Or achieve **60fps** easily
- Or add post-processing (bloom, blur, etc.)

---

## Recommended System Configuration

### Target Specification

**Hardware:**
- Resolution: **800×600** (SVGA)
- Clock: **125MHz** (system + SDRAM)
- Shader cores: **4 parallel cores**
- VGA pixel clock: **40MHz** (VESA standard)

**Performance:**
- Base framerate: **15 fps** (69 cycles/pixel budget)
- Procedural mode: **30 fps** (11× margin with 100 primitives)
- Quarter-res mode: **60 fps** (277 cycles/pixel budget)

**Resource utilization:**
- Logic Elements: ~3,200 LEs (51% of 6,272)
  - 4 shader cores: 1,800 LEs
  - SDRAM controller: 800 LEs
  - VGA + rasterizer: 500 LEs
  - Misc (UART, display): 600 LEs
- Block RAM: ~8.2 KiB (24% of 34 KiB)
  - VGA line buffers: 3.2 KiB
  - Register files: 1 KiB
  - Constant stacks: 4 KiB

**Memory layout (SDRAM):**
```
0x000000 - 0x0EA5FF   Framebuffer 0 (938 KiB, 800×600 RGB565)
0x0EA600 - 0x1D4BFF   Framebuffer 1 (938 KiB, double-buffer)
0x1D4C00 - 0x214BFF   Font/Glyph SDF Atlas (256 KiB)
0x214C00 - 0x614BFF   Texture Pages (4 MiB)
0x900000 - 0x903FFF   Constant Pool (16 KiB, 8192×16-bit)
0x904000 - 0x1FFFFFF  Free space (~24 MiB)
```

### Rendering Modes

**Mode 1: Full-Resolution Raster (15 fps)**
- 800×600 native shading
- 69 cycles per pixel budget
- Single texture + lighting
- Good for texture-heavy scenes

**Mode 2: Procedural Graphics (30 fps)**
- Vector primitives (circles, rects, text)
- 100+ primitives per frame
- Infinite zoom (resolution-independent)
- Perfect for UI, data visualization, CAD

**Mode 3: Temporal Upscaling (30 fps)**
- Shade 400×300, upscale to 800×600
- 277 cycles per pixel budget
- Multi-texture + complex effects
- Good for dynamic scenes

**Mode 4: Hybrid (30 fps)**
- Procedural UI layer (vector sharp)
- Raster 3D background (quarter-res)
- Composite in framebuffer
- Best of both worlds

---

## Implementation Roadmap

### Phase 1: Foundation (Current)
- ✅ Single-core 16-bit ISA
- ✅ SDRAM integration (100MHz)
- ✅ VGA output (1024×768@60Hz)
- ✅ Line-buffered scanout

### Phase 2: Multi-Core Shader Pipeline
**Phase 2a: Core Replication**
1. Migrate to 800×600 resolution (40MHz VGA)
2. Upgrade sys_pll to 125MHz
3. Replicate shader core module (4 instances)
4. Implement SDRAM arbiter with round-robin scheduling
5. Add shader invocation FSM
6. Test: parallel fill shader (verify 4× speedup)

**Phase 2b: Raster Shading**
1. Implement hardware pixel coordinate registers (r1=x, r2=y)
2. Add framebuffer read-modify-write support
3. Test: texture mapping shader
4. Test: lighting shader
5. Benchmark: measure cycles per pixel

**Phase 2c: Procedural Rendering**
1. Implement rasterizer module (200 LEs)
2. Add primitive buffer in SDRAM
3. Geometry shader: circle primitive
4. Fragment shader: circle SDF evaluator
5. Test: render 100 circles @ 30fps
6. Expand primitive library (rect, line, rounded rect)

### Phase 3: Advanced Features
**Phase 3a: Temporal Upscaling**
1. Add bilinear upscaler module (100-150 LEs)
2. Implement quarter-res rendering mode
3. Frame scheduler FSM (adaptive resolution)
4. Test: 400×300 → 800×600 upscale quality

**Phase 3b: Text Rendering**
1. Generate SDF font atlas (offline tool)
2. Glyph lookup shader
3. Text layout engine (CPU-side)
4. UTF-8 support

**Phase 3c: Post-Processing**
1. Bloom effect (downsample + blur + composite)
2. Simple blur (box filter)
3. Color grading LUT

---

## Example Shader Code

### Simple Texture Mapper (35 cycles)

```assembly
shader_texture:
    ; r1 = pixel_x (hardware), r2 = pixel_y (hardware)

    LDC  tex_base         ; Load texture base address (1 cycle, cached)
    LDCS r3               ; r3 = texture base (1 cycle)

    ; Compute texture address: base + y*width + x
    LDC  tex_width        ; (1 cycle)
    LDCS r4               ; (1 cycle)
    MUL  r5, r2, r4       ; offset = y * width (1 cycle)
    ADD  r5, r5, r1       ; offset += x (1 cycle)
    ADD  r3, r3, r5       ; address = base + offset (1 cycle)

    LOAD r0, [r3]         ; Sample texture (18 cycles SDRAM)
    RET                   ; Write to framebuffer

; Total: ~25 cycles (comfortably under 35-cycle budget @ 30fps)
```

### Phong Lighting (60 cycles)

```assembly
shader_phong:
    ; r1 = pixel_x, r2 = pixel_y

    ; Sample base color texture
    LDC  tex_base
    LDCS r3
    ADD  r3, r1           ; Simple UV mapping
    LOAD r4, [r3]         ; base_color (18 cycles)

    ; Load light position
    LDC  light_x
    LDCS r5
    LDC  light_y
    LDCS r6

    ; Compute distance to light
    SUB  r7, r5, r1       ; dx = light_x - pixel_x (1 cycle)
    SUB  r8, r6, r2       ; dy = light_y - pixel_y (1 cycle)
    MUL  r7, r7           ; dx² (1 cycle)
    MUL  r8, r8           ; dy² (1 cycle)
    ADD  r9, r7, r8       ; dist² (1 cycle)

    ; Attenuation: brightness = k / (1 + dist²)
    LDC  light_intensity  ; k constant
    LDCS r10
    ADDI r9, 1            ; (1 + dist²)
    DIV  r11, r10, r9     ; attenuation (5 cycles if DIV unit)

    ; Modulate base color by attenuation
    MUL  r0, r4, r11      ; final_color = base * attenuation (1 cycle)
    SHR  r0, 8            ; Normalize (fixed-point) (1 cycle)

    RET

; Total: ~50-55 cycles (fits in 69-cycle budget @ 15fps)
```

### Procedural Circle (28 cycles)

```assembly
shader_circle:
    ; r1 = pixel_x, r2 = pixel_y
    ; Primitive data in constant pool

    LDC  circle_data
    LDCS r10
    LOAD r3, [r10]        ; center_x (18 cycles)
    LOAD r4, [r10+1]      ; center_y (1 cycle)
    LOAD r5, [r10+2]      ; radius (1 cycle)

    SUB  r6, r1, r3       ; dx (1 cycle)
    SUB  r7, r2, r4       ; dy (1 cycle)
    MUL  r6, r6           ; dx² (1 cycle)
    MUL  r7, r7           ; dy² (1 cycle)
    ADD  r8, r6, r7       ; dist² (1 cycle)
    MUL  r9, r5, r5       ; radius² (1 cycle)

    CMP  r8, r9           ; Compare dist² vs radius² (1 cycle)
    JLT  fill             ; Jump if inside

    MOV  r0, 0x0000       ; Outside: transparent (1 cycle)
    RET

fill:
    LOAD r0, [r10+3]      ; fill_color (1 cycle)
    RET

; Total: ~28 cycles (only runs for pixels in bounding box!)
```

---

## Conclusion

The recommended **4-core, 125MHz, 800×600** configuration provides:

✅ **Sufficient performance:** 69 cycles/pixel @ 15fps, or 277 cycles/pixel @ 60fps (quarter-res)
✅ **Flexible rendering:** Support both raster and procedural graphics
✅ **Low bandwidth:** 22% SDRAM utilization leaves room for texture streaming
✅ **Scalable:** Can add more cores (up to 8) or clock speed (up to 143MHz)
✅ **Resource efficient:** 51% LE, 24% Block RAM utilization

**Key innovation:** Procedural vector graphics provide **100× performance gain** over texture-based rendering for geometric primitives, enabling real-time UI and data visualization with minimal memory bandwidth.

This architecture transforms the FPGA into a capable graphics accelerator suitable for retro gaming, embedded HMI, data visualization, and CAD applications.
