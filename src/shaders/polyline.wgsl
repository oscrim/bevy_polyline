#import bevy_render::view::View



@group(0) @binding(0)
var<uniform> view: View;

struct PolylineView {
    focus_point: vec3<f32>,
    highlight_height: f32,
    drop_above: f32,
    drop_below: f32,
    drop_above_min_val: f32,
    drop_below_min_val: f32,
};

@group(0) @binding(1) var<uniform> polyline_view: PolylineView;

struct Polyline {
    model: mat4x4<f32>,
};

@group(1) @binding(0)
var<uniform> polyline: Polyline;

struct PolylineMaterial {
    color: vec4<f32>,
    depth_bias: f32,
    width: f32,
    max_clip_w: f32,
};

@group(2) @binding(0)
var<uniform> material: PolylineMaterial;

struct Vertex {
    @location(0) point_a: vec3<f32>,
    @location(1) point_b: vec3<f32>,
    @builtin(vertex_index) index: u32,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vertex(vertex: Vertex) -> VertexOutput {
    var positions = array<vec3<f32>, 6u>(
        vec3(0.0, -0.5, 0.0),
        vec3(0.0, -0.5, 1.0),
        vec3(0.0, 0.5, 1.0),
        vec3(0.0, -0.5, 0.0),
        vec3(0.0, 0.5, 1.0),
        vec3(0.0, 0.5, 0.0)
    );
    let position = positions[vertex.index];

    // algorithm based on https://wwwtyro.net/2019/11/18/instanced-lines.html
    var clip0 = view.clip_from_world * polyline.model * vec4(vertex.point_a, 1.0);
    var clip1 = view.clip_from_world * polyline.model * vec4(vertex.point_b, 1.0);

    // Manual near plane clipping to avoid errors when doing the perspective divide inside this shader.
    clip0 = clip_near_plane(clip0, clip1);
    clip1 = clip_near_plane(clip1, clip0);

    #ifdef POLYLINE_MAX_CLIP_W
        clip0 = clip_far_plane(clip0, clip1, material.max_clip_w);
        clip1 = clip_far_plane(clip1, clip0, material.max_clip_w);

        if clip0.w > material.max_clip_w && clip1.w > material.max_clip_w {
            return VertexOutput(
                vec4(0.0, 0.0, 2.0, 1.0),
                vec4(0.0)
            );
        }
    #endif

    let clip = mix(clip0, clip1, position.z);

    let resolution = vec2(view.viewport.z, view.viewport.w);
    let screen0 = resolution * (0.5 * clip0.xy / clip0.w + 0.5);
    let screen1 = resolution * (0.5 * clip1.xy / clip1.w + 0.5);

    let x_basis = normalize(screen1 - screen0);
    let y_basis = vec2(-x_basis.y, x_basis.x);

    var line_width = material.width;
    var color = material.color;

    #ifdef POLYLINE_FOCUS_POINT
        let world0 = (polyline.model * vec4(vertex.point_a, 1.0)).xyz;
        let world1 = (polyline.model * vec4(vertex.point_b, 1.0)).xyz;
        let world_pos = mix(world0, world1, position.z);

        let focus_to_pos = world_pos - polyline_view.focus_point;
        let camera_pos = vec3(view.world_from_view[3][0], view.world_from_view[3][1], view.world_from_view[3][2]);
        let cam_to_focus = polyline_view.focus_point - camera_pos;

        let t = dot(focus_to_pos, cam_to_focus) / dot(cam_to_focus, cam_to_focus);

        let delta_y = world_pos.y - polyline_view.focus_point.y; // signed height
        let h = abs(delta_y);
        let dead_zone = polyline_view.highlight_height;

        if (h > dead_zone && t < 0.0 && delta_y > 0.0) {
            //return VertexOutput(vec4(0.0, 0.0, 2.0, 1.0), vec4(0.0));
            color.a = 0.0;
        }

        let drop_above = polyline_view.drop_above;   // meters for smooth first drop above focus
        let drop_below = polyline_view.drop_below;   // meters for smooth first drop below focus
        let first_drop_min_below = polyline_view.drop_below_min_val; // below: drop to 30%
        let first_drop_min_above = polyline_view.drop_above_min_val; // above: drop to 10%

        var scale = 1.0;

        if (h > dead_zone) {
            // choose drop range based on above/below
            let drop_range = select(drop_below, drop_above, delta_y > 0.0); // delta_y >0 → above
            let target_min = select(first_drop_min_below, first_drop_min_above, delta_y > 0.0);

            let x = h - dead_zone;
            scale = mix(1.0, target_min, clamp(x / drop_range, 0.0, 1.0));
        }

        if (delta_y < 0.0 && h > dead_zone + drop_below) {
            // Tail only applies below focus
            let tail_h = h - (dead_zone + drop_below);
            let tail_scale = pow(1.0 + tail_h * 0.1, -0.5); // slow decay
            scale *= tail_scale;
        }

        let min_scale = 0.05;
        scale = max(min_scale, scale);

        line_width *= scale;

        //color = vec4(scale, 1.0 - scale, 1.0 - scale, 1.0);

        color.a *= smoothstep(0.0, 0.2, scale);

        //line_width /= clip.w;
        // Line thinness fade from https://acegikmo.com/shapes/docs/#anti-aliasing
        if (line_width > 0.0 && line_width < 1.0) {
            color.a *= line_width;
            line_width = 1.0;
        }
    #endif

    let pt_offset = line_width * (position.x * x_basis + position.y * y_basis);
    let pt0 = screen0 + pt_offset;
    let pt1 = screen1 + pt_offset;
    let pt = mix(pt0, pt1, position.z);

    var depth: f32 = clip.z;
    if (material.depth_bias >= 0.0) {
        depth = depth * (1.0 - material.depth_bias);
    } else {
        let epsilon = 4.88e-04;
        // depth * (clip.w / depth)^-depth_bias. So that when -depth_bias is 1.0, this is equal to clip.w
        // and when equal to 0.0, it is exactly equal to depth.
        // the epsilon is here to prevent the depth from exceeding clip.w when -depth_bias = 1.0
        // clip.w represents the near plane in homogenous clip space in bevy, having a depth
        // of this value means nothing can be in front of this
        // The reason this uses an exponential function is that it makes it much easier for the
        // user to chose a value that is convenient for them
        depth = depth * exp2(-material.depth_bias * log2(clip.w / depth - epsilon));
    }

    return VertexOutput(vec4(clip.w * ((2.0 * pt) / resolution - 1.0), depth, clip.w), color);
}

fn clip_near_plane(a: vec4<f32>, b: vec4<f32>) -> vec4<f32> {
    // Move a if a is behind the near plane and b is in front.
    if a.z > a.w && b.z <= b.w {
        // Interpolate a towards b until it's at the near plane.
        let distance_a = a.z - a.w;
        let distance_b = b.z - b.w;
        let t = distance_a / (distance_a - distance_b);
        return a + (b - a) * t;
    }
    return a;
}

fn clip_far_plane(a: vec4<f32>, b: vec4<f32>, max_w: f32) -> vec4<f32> {
    if a.w > max_w && b.w <= max_w {
        let t = (max_w - a.w) / (b.w - a.w);
        return a + (b - a) * t;
    }
    return a;
}

struct FragmentInput {
    @location(0) color: vec4<f32>,
};

@fragment
fn fragment(in: FragmentInput) -> @location(0) vec4<f32> {
    return in.color;
}
