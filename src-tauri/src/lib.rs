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
    let mut cmd = if cfg!(debug_assertions) {
        // Dev: run the sidecar from the uv venv via the source tree.
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        let mut c = Command::new(root.join(".venv/bin/python"));
        c.arg(root.join("sidecar/server.py"));
        c
    } else {
        // Bundled: the PyInstaller sidecar sits next to the app executable
        // (Tauri externalBin lands in Contents/MacOS/, triple suffix stripped).
        let exe_dir = std::env::current_exe()
            .expect("current_exe")
            .parent()
            .expect("exe parent")
            .to_path_buf();
        Command::new(exe_dir.join("photo-cleanup-sidecar"))
    };
    let child = cmd
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
