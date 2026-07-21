use std::net::TcpListener;
use std::path::Path;
use std::process::{Child, Command};
use std::sync::Mutex;

use tauri::Manager;

/// Holds the sidecar's port (for the frontend) and its process handle (to kill on exit).
struct Sidecar {
    port: u16,
    child: Mutex<Option<Child>>,
}

#[tauri::command]
fn sidecar_port(state: tauri::State<Sidecar>) -> u16 {
    state.port
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("bind ephemeral port")
        .local_addr()
        .unwrap()
        .port()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let port = free_port();
    // ponytail: dev-only path resolution via compile-time manifest dir.
    // Phase 6 (packaging) replaces this with a bundled sidecar binary.
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let py = root.join(".venv/bin/python");
    let script = root.join("sidecar/server.py");
    let child = Command::new(&py)
        .arg(&script)
        .arg("--port")
        .arg(port.to_string())
        .spawn()
        .expect("failed to spawn python sidecar");

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(Sidecar {
            port,
            child: Mutex::new(Some(child)),
        })
        .invoke_handler(tauri::generate_handler![sidecar_port])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                if let Some(sc) = app.try_state::<Sidecar>() {
                    if let Some(mut c) = sc.child.lock().unwrap().take() {
                        let _ = c.kill();
                    }
                }
            }
        });
}
