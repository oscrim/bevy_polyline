use bevy::{
    color::palettes::css::{BLUE, RED},
    prelude::*,
    render::view::Hdr,
};
use bevy_polyline::{polyline::PolylineFocusPoint, prelude::*};

fn main() {
    App::new()
        .init_resource::<ChosenFocusPoint>()
        .init_resource::<FocusLerp>()
        .add_plugins(DefaultPlugins)
        .add_plugins(PolylinePlugin)
        .add_systems(Startup, setup)
        .add_systems(
            Update,
            (
                move_camera,
                toggle_focus_point,
                toggle_focus_point_position,
                move_focus_point,
            ),
        )
        .run();
}

const FOCUS_POINT: Vec3 = Vec3::new(0.0, 0.0, 1.0);
const FOCUS_POINT2: Vec3 = Vec3::new(0.0, 1.0, 1.0);

#[derive(Debug, Resource, Default, Clone, Copy)]
enum ChosenFocusPoint {
    #[default]
    Point1,
    Point2,
}

impl ChosenFocusPoint {
    fn get_point(&self) -> Vec3 {
        match self {
            ChosenFocusPoint::Point1 => FOCUS_POINT,
            ChosenFocusPoint::Point2 => FOCUS_POINT2,
        }
    }

    fn toggle(&mut self) {
        *self = match self {
            ChosenFocusPoint::Point1 => ChosenFocusPoint::Point2,
            ChosenFocusPoint::Point2 => ChosenFocusPoint::Point1,
        };
    }
}

fn setup(
    mut commands: Commands,
    mut polyline_materials: ResMut<Assets<PolylineMaterial>>,
    mut polylines: ResMut<Assets<Polyline>>,
    chosen_focus_point: Res<ChosenFocusPoint>,
) {
    let mut vertices = Vec::new();
    const NUM_POINTS: usize = 51;
    const SPREAD: f32 = 2.0;

    for i in 0..NUM_POINTS {
        let v =
            (Vec3::NEG_ONE * SPREAD).lerp(Vec3::ONE * SPREAD, i as f32 / (NUM_POINTS - 1) as f32);
        vertices.push(v);
    }

    commands.spawn(PolylineBundle {
        polyline: PolylineHandle(polylines.add(Polyline { vertices })),
        material: PolylineMaterialHandle(polyline_materials.add(PolylineMaterial {
            width: 10.0,
            color: RED.into(),
            ..default()
        })),
        ..default()
    });

    commands.spawn(PolylineBundle {
        polyline: PolylineHandle(polylines.add(Polyline {
            vertices: vec![Vec3::new(-1.0, 0.0, 0.0), Vec3::new(1.0, 0.0, 0.0)],
        })),
        material: PolylineMaterialHandle(polyline_materials.add(PolylineMaterial {
            width: 10.0,
            color: BLUE.into(),
            ..default()
        })),
        ..default()
    });

    // camera
    commands.spawn((
        Camera3d::default(),
        PolylineFocusPoint {
            focus_point: chosen_focus_point.get_point(),
            highlight_height: 0.1,
            drop_above: 0.2,
            drop_below: 0.3,
            ..Default::default()
        },
        Msaa::Sample4,
        Transform::from_xyz(0.0, 0.0, 4.0).looking_at(Vec3::ZERO, Vec3::Y),
        Camera::default(),
        Hdr,
    ));
}

fn move_camera(
    mut q: Query<&mut Transform, With<Camera>>,
    keyboard_input: Res<ButtonInput<KeyCode>>,
    time: Res<Time>,
) {
    let speed = 5.0;
    for mut t in &mut q {
        let mut dir = Vec3::ZERO;
        if keyboard_input.pressed(KeyCode::KeyW) {
            dir.z -= 1.0;
        }
        if keyboard_input.pressed(KeyCode::KeyS) {
            dir.z += 1.0;
        }
        if keyboard_input.pressed(KeyCode::KeyA) {
            dir.x -= 1.0;
        }
        if keyboard_input.pressed(KeyCode::KeyD) {
            dir.x += 1.0;
        }
        if keyboard_input.pressed(KeyCode::KeyQ) {
            dir.y -= 1.0;
        }
        if keyboard_input.pressed(KeyCode::KeyE) {
            dir.y += 1.0;
        }
        t.translation += dir * time.delta_secs() * speed;
    }
}

fn toggle_focus_point(
    mut polyline_focus_point: Single<&mut PolylineFocusPoint>,
    keyboard_input: Res<ButtonInput<KeyCode>>,
    chosen_focus_point: Res<ChosenFocusPoint>,
) {
    if keyboard_input.just_pressed(KeyCode::KeyX) {
        if polyline_focus_point.enabled() {
            polyline_focus_point.disable();
        } else {
            polyline_focus_point.focus_point = chosen_focus_point.get_point();
        }
    }
}

fn toggle_focus_point_position(
    polyline_focus_point: Single<&PolylineFocusPoint>,
    keyboard_input: Res<ButtonInput<KeyCode>>,
    mut chosen_focus_point: ResMut<ChosenFocusPoint>,
    mut focus_lerp: ResMut<FocusLerp>,
) {
    if keyboard_input.just_pressed(KeyCode::KeyZ) && polyline_focus_point.enabled() {
        chosen_focus_point.toggle();
        focus_lerp.start = polyline_focus_point.focus_point;
        focus_lerp.end = chosen_focus_point.get_point();
        focus_lerp.duration = 2.0;
        focus_lerp.elapsed = 0.0;
    }
}

#[derive(Debug, Resource, Default)]
struct FocusLerp {
    start: Vec3,
    end: Vec3,
    duration: f32,
    elapsed: f32,
}

impl FocusLerp {
    fn finished(&self) -> bool {
        self.elapsed >= self.duration
    }
}

fn move_focus_point(
    mut polyline_focus_point: Single<&mut PolylineFocusPoint>,
    time: Res<Time>,
    mut focus_lerp: ResMut<FocusLerp>,
) {
    if polyline_focus_point.disabled() || focus_lerp.finished() {
        return;
    }

    focus_lerp.elapsed += time.delta_secs();
    let starting = focus_lerp.start;
    let chosen = focus_lerp.end;
    let s = (focus_lerp.elapsed / focus_lerp.duration).min(1.0);
    let new = starting.lerp(chosen, s);
    polyline_focus_point.focus_point = new;
}
