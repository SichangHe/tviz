//! Terminal + viz pane. The pty runs the user's login shell locally, like Kitty.
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::io::{Read, Write};
use std::sync::Mutex;
use tauri::{ipc::{Channel, InvokeBody, Request, Response}, State};

struct Pty {
    master: Mutex<Option<Box<dyn MasterPty + Send>>>,
    writer: Mutex<Option<Box<dyn Write + Send>>>,
}

#[tauri::command]
fn pty_spawn(app: tauri::AppHandle, st: State<Pty>, cols: u16, rows: u16, out: Channel<Response>) -> Result<(), String> {
    if st.master.lock().unwrap().is_some() {
        return Ok(());
    }
    let pair = native_pty_system()
        .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
        .map_err(|e| e.to_string())?;
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let mut cmd = CommandBuilder::new(shell);
    cmd.arg("-l");
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    cmd.env("TERM_PROGRAM", "tviz");
    if std::env::var_os("LANG").is_none() {
        cmd.env("LANG", "en_US.UTF-8");
    }
    if let Some(home) = std::env::var_os("HOME") {
        cmd.cwd(home);
    }
    let mut child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
    drop(pair.slave);
    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    *st.writer.lock().unwrap() = Some(pair.master.take_writer().map_err(|e| e.to_string())?);
    *st.master.lock().unwrap() = Some(pair.master);
    std::thread::spawn(move || {
        let mut buf = [0u8; 16384];
        while let Ok(n) = reader.read(&mut buf) {
            if n == 0 { break; }
            if out.send(Response::new(buf[..n].to_vec())).is_err() { break; }
        }
    });
    std::thread::spawn(move || {
        let _ = child.wait();
        app.exit(0);
    });
    Ok(())
}

#[tauri::command]
fn pty_write(st: State<Pty>, req: Request) {
    if let (InvokeBody::Raw(data), Some(w)) = (req.body(), st.writer.lock().unwrap().as_mut()) {
        let _ = w.write_all(data);
    }
}

#[tauri::command]
fn pty_resize(st: State<Pty>, cols: u16, rows: u16) {
    if let Some(m) = st.master.lock().unwrap().as_ref() {
        let _ = m.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 });
    }
}

fn main() {
    tauri::Builder::default()
        .manage(Pty { master: Mutex::new(None), writer: Mutex::new(None) })
        .invoke_handler(tauri::generate_handler![pty_spawn, pty_write, pty_resize])
        .run(tauri::generate_context!())
        .expect("tauri run");
}
