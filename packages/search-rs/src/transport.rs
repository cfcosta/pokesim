//! Batched Lean simulator wire protocol. Battle semantics remain in Lean.
use crate::Request;
use base64::Engine;
use serde::{
    de::{SeqAccess, Visitor},
    Deserialize, Deserializer,
};
use std::{
    borrow::Cow,
    fmt,
    fmt::Write as _,
    panic::{catch_unwind, AssertUnwindSafe},
    slice,
    time::{Duration, Instant},
};

#[derive(Debug)]
struct Error {
    code: i32,
    message: String,
}
impl From<String> for Error {
    fn from(message: String) -> Self {
        Self { code: 1, message }
    }
}
type Result<T> = std::result::Result<T, Error>;

// Borrow the common unescaped base64 string directly from the response.
// serde's untagged enum path would allocate and then clone each feature string.
enum Features<'a> {
    Packed(Cow<'a, str>),
    Numbers(Vec<i64>),
}
struct FeatureVisitor;
impl<'de> Visitor<'de> for FeatureVisitor {
    type Value = Features<'de>;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("a packed feature string or integer array")
    }
    fn visit_borrowed_str<E: serde::de::Error>(
        self,
        value: &'de str,
    ) -> std::result::Result<Self::Value, E> {
        Ok(Features::Packed(Cow::Borrowed(value)))
    }
    fn visit_str<E: serde::de::Error>(self, value: &str) -> std::result::Result<Self::Value, E> {
        Ok(Features::Packed(Cow::Owned(value.to_owned())))
    }
    fn visit_string<E: serde::de::Error>(self, value: String) -> std::result::Result<Self::Value, E> {
        Ok(Features::Packed(Cow::Owned(value)))
    }
    fn visit_seq<A: SeqAccess<'de>>(
        self,
        mut sequence: A,
    ) -> std::result::Result<Self::Value, A::Error> {
        let mut values = Vec::new();
        while let Some(value) = sequence.next_element()? {
            values.push(value);
        }
        Ok(Features::Numbers(values))
    }
}
impl<'de: 'a, 'a> Deserialize<'de> for Features<'a> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        deserializer.deserialize_any(FeatureVisitor)
    }
}
#[derive(Deserialize)]
struct WireSnapshot<'a> {
    handle: u64,
    #[serde(borrow)]
    player_features: Features<'a>,
    #[serde(borrow)]
    enemy_features: Features<'a>,
    #[serde(default)]
    feature_encoding: Option<String>,
    player_mask: u64,
    enemy_mask: u64,
    player_hash: String,
    enemy_hash: String,
    turn: u64,
    terminal: bool,
    done: bool,
    #[serde(rename = "return", deserialize_with = "Option::deserialize")]
    terminal_return: Option<i64>,
    request: String,
    #[serde(default)]
    divergence: Option<String>,
    #[serde(default)]
    player_popular: bool,
    #[serde(default)]
    enemy_popular: bool,
}
#[derive(Deserialize)]
struct Response<'a> {
    id: String,
    ok: bool,
    error: Option<String>,
    #[serde(borrow)]
    snapshots: Option<Vec<WireSnapshot<'a>>>,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Span {
    offset: u64,
    len: u64,
}
#[repr(C)]
#[derive(Default)]
pub struct SnapshotRow {
    handle: u64,
    player_mask: u64,
    enemy_mask: u64,
    turn: u64,
    terminal: u64,
    done: u64,
    has_return: u64,
    terminal_return: i64,
    player_popular: u64,
    enemy_popular: u64,
    has_divergence: u64,
    feature_kind: u64,
    player_features: Span,
    enemy_features: Span,
    player_hash: Span,
    enemy_hash: Span,
    request: Span,
    divergence: Span,
}
#[derive(Default)]
pub struct Batch {
    rows: Vec<SnapshotRow>,
    features: Vec<u8>,
    text: Vec<u8>,
    error: String,
}
#[repr(C)]
pub struct BatchView {
    rows: *const SnapshotRow,
    count: usize,
    features: *const u8,
    feature_bytes: usize,
    text: *const u8,
    text_bytes: usize,
}
fn append(buffer: &mut Vec<u8>, bytes: &[u8]) -> Span {
    let span = Span {
        offset: buffer.len() as u64,
        len: bytes.len() as u64,
    };
    buffer.extend_from_slice(bytes);
    span
}
fn features(buffer: &mut Vec<u8>, values: Features<'_>, packed: bool, count: usize) -> Result<Span> {
    let offset = buffer.len();
    match (packed, values) {
        (true, Features::Packed(value)) => {
            // Match Python's strict alphabet/padding checks, including acceptance
            // of noncanonical unused trailing bits in otherwise valid base64.
            let decoder = base64::engine::GeneralPurpose::new(
                &base64::alphabet::STANDARD,
                base64::engine::GeneralPurposeConfig::new().with_decode_allow_trailing_bits(true),
            );
            decoder
                .decode_vec(value.as_bytes(), buffer)
                .map_err(|e| format!("invalid packed native features: {e}"))?;
            if !(buffer.len() - offset).is_multiple_of(2) {
                return Err("packed native features have odd byte length"
                    .to_owned()
                    .into());
            }
        }
        (false, Features::Numbers(values)) => {
            for value in values {
                buffer.extend_from_slice(&value.to_le_bytes());
            }
        }
        _ => {
            return Err("native feature encoding does not match its payload"
                .to_owned()
                .into())
        }
    }
    let len = buffer.len() - offset;
    if len
        != count
            .checked_mul(if packed { 2 } else { 8 })
            .ok_or("feature count overflow".to_owned())?
    {
        return Err("native search state feature count differs from schema"
            .to_owned()
            .into());
    }
    Ok(Span {
        offset: offset as u64,
        len: len as u64,
    })
}
fn decode(data: &[u8], id: u64, count: usize, feature_count: usize) -> Result<Batch> {
    let response: Response =
        serde_json::from_slice(data).map_err(|e| format!("invalid native response: {e}"))?;
    if response.id != id.to_string() {
        return Err("search response ID mismatch".to_owned().into());
    }
    if !response.ok {
        return Err(format!(
            "native search operation failed: {}",
            response.error.unwrap_or_else(|| "missing error".into())
        )
        .into());
    }
    let snapshots = response
        .snapshots
        .ok_or("native batch response missing snapshots".to_owned())?;
    if snapshots.len() != count {
        return Err("native batch response length mismatch".to_owned().into());
    }
    let mut batch = Batch::default();
    batch.rows.reserve(count);
    for s in snapshots {
        let packed = match s.feature_encoding.as_deref().unwrap_or("json-nat-array") {
            "u16le-base64" => true,
            "json-nat-array" => false,
            other => return Err(format!("unsupported native feature encoding: {other:?}").into()),
        };
        batch.rows.push(SnapshotRow {
            handle: s.handle,
            player_mask: s.player_mask,
            enemy_mask: s.enemy_mask,
            turn: s.turn,
            terminal: s.terminal as u64,
            done: s.done as u64,
            has_return: s.terminal_return.is_some() as u64,
            terminal_return: s.terminal_return.unwrap_or(0),
            player_popular: s.player_popular as u64,
            enemy_popular: s.enemy_popular as u64,
            has_divergence: s.divergence.is_some() as u64,
            feature_kind: packed as u64,
            player_features: features(
                &mut batch.features,
                s.player_features,
                packed,
                feature_count,
            )?,
            enemy_features: features(&mut batch.features, s.enemy_features, packed, feature_count)?,
            player_hash: append(&mut batch.text, s.player_hash.as_bytes()),
            enemy_hash: append(&mut batch.text, s.enemy_hash.as_bytes()),
            request: append(&mut batch.text, s.request.as_bytes()),
            divergence: append(&mut batch.text, s.divergence.unwrap_or_default().as_bytes()),
        });
    }
    Ok(batch)
}
fn encode(id: u64, episode: bool, rows: &[Request]) -> Vec<u8> {
    let mut output = String::with_capacity(rows.len().saturating_mul(40));
    write!(
        output,
        "{}|{id}|",
        if episode { "batch-episode" } else { "batch" }
    )
    .unwrap();
    for (i, r) in rows.iter().enumerate() {
        if i != 0 {
            output.push(';');
        }
        write!(
            output,
            "{},{},{},{}",
            r.handle,
            r.player,
            r.enemy,
            if episode { 0 } else { r.seed }
        )
        .unwrap();
    }
    output.push('\n');
    output.into_bytes()
}
fn wait(fd: i32, event: i16, deadline: Instant) -> Result<()> {
    loop {
        let left = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| Error {
                code: 2,
                message: "native request timed out".into(),
            })?;
        let millis = left.as_millis().saturating_add(1).min(i32::MAX as u128) as i32;
        let mut descriptor = libc::pollfd {
            fd,
            events: event,
            revents: 0,
        };
        // The descriptor is borrowed for this synchronous call; Python owns it.
        let ready = unsafe { libc::poll(&mut descriptor, 1, millis) };
        if ready < 0 {
            let e = std::io::Error::last_os_error();
            if e.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(format!("native pipe poll failed: {e}").into());
        }
        if ready == 0 {
            continue;
        }
        if descriptor.revents & libc::POLLNVAL != 0 {
            return Err("native pipe descriptor is closed".to_owned().into());
        }
        return Ok(()); // HUP/ERR must reach read/write to report EOF/broken pipe.
    }
}
fn exchange(input: i32, output: i32, wire: &[u8], deadline: Instant) -> Result<Vec<u8>> {
    let mut sent = 0;
    while sent < wire.len() {
        wait(input, libc::POLLOUT, deadline)?;
        // A single writer and <= PIPE_BUF bytes avoid an unbounded blocking
        // write after poll. This library is called with the Python request lock.
        let chunk = &wire[sent..(sent + libc::PIPE_BUF).min(wire.len())];
        let n = unsafe { libc::write(input, chunk.as_ptr().cast(), chunk.len()) };
        if n <= 0 {
            let e = std::io::Error::last_os_error();
            if n < 0 && e.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(format!("native pipe write failed: {e}").into());
        }
        sent += n as usize;
    }
    let mut response = Vec::new();
    let mut buffer = [0u8; 65536];
    loop {
        wait(output, libc::POLLIN, deadline)?;
        let n = unsafe { libc::read(output, buffer.as_mut_ptr().cast(), buffer.len()) };
        if n < 0 {
            let e = std::io::Error::last_os_error();
            if e.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(format!("native pipe read failed: {e}").into());
        }
        if n == 0 {
            return Err("search server exited unexpectedly (EOF)".to_owned().into());
        }
        response.extend_from_slice(&buffer[..n as usize]);
        if let Some(end) = buffer[..n as usize].iter().position(|b| *b == b'\n') {
            if end + 1 != n as usize {
                return Err("unexpected data after native response".to_owned().into());
            }
            return Ok(response);
        }
    }
}
#[allow(clippy::too_many_arguments)]
fn request(
    input: i32,
    output: i32,
    id: u64,
    episode: bool,
    rows: &[Request],
    feature_count: usize,
    timeout: f64,
) -> Result<Batch> {
    if input < 0 || output < 0 || rows.is_empty() || !timeout.is_finite() || timeout <= 0.0 {
        return Err("invalid native batch transport arguments".to_owned().into());
    }
    let duration =
        Duration::try_from_secs_f64(timeout).map_err(|_| "invalid request timeout".to_owned())?;
    let deadline = Instant::now()
        .checked_add(duration)
        .ok_or("request timeout overflow".to_owned())?;
    let wire = encode(id, episode, rows);
    let response = exchange(input, output, &wire, deadline)?;
    decode(&response, id, rows.len(), feature_count)
}

fn finish(out: *mut *mut Batch, work: impl FnOnce() -> Result<Batch>) -> i32 {
    if out.is_null() {
        return 1;
    }
    let (batch, code) = match catch_unwind(AssertUnwindSafe(work)) {
        Ok(Ok(batch)) => (batch, 0),
        Ok(Err(error)) => (
            Batch {
                error: error.message,
                ..Batch::default()
            },
            error.code,
        ),
        Err(_) => (
            Batch {
                error: "Rust simulator transport panicked".into(),
                ..Batch::default()
            },
            1,
        ),
    };
    unsafe {
        *out = Box::into_raw(Box::new(batch));
    }
    code
}
#[no_mangle]
pub extern "C" fn battle_transport_abi_v1() -> u64 {
    1
}
/// # Safety
/// Input bytes must be valid for len; out must be writable. Free returned batch.
#[no_mangle]
pub unsafe extern "C" fn battle_transport_decode_v1(
    data: *const u8,
    len: usize,
    id: u64,
    count: usize,
    feature_count: usize,
    out: *mut *mut Batch,
) -> i32 {
    finish(out, || {
        if data.is_null() {
            return Err("null response bytes".to_owned().into());
        }
        decode(slice::from_raw_parts(data, len), id, count, feature_count)
    })
}
/// # Safety
/// Pipes must be live, exclusively borrowed and blocking. Rows/out must be valid.
#[no_mangle]
pub unsafe extern "C" fn battle_transport_batch_v1(
    input: i32,
    output: i32,
    id: u64,
    episode: u64,
    rows: *const Request,
    count: usize,
    feature_count: usize,
    timeout: f64,
    out: *mut *mut Batch,
) -> i32 {
    finish(out, || {
        if rows.is_null() {
            return Err("invalid native batch transport arguments".to_owned().into());
        }
        request(
            input,
            output,
            id,
            episode != 0,
            slice::from_raw_parts(rows, count),
            feature_count,
            timeout,
        )
    })
}
/// # Safety
/// batch must be a live returned batch and view writable; views expire on free.
#[no_mangle]
pub unsafe extern "C" fn battle_transport_view_v1(batch: *const Batch, view: *mut BatchView) -> i32 {
    if batch.is_null() || view.is_null() {
        return 1;
    }
    let b = &*batch;
    *view = BatchView {
        rows: b.rows.as_ptr(),
        count: b.rows.len(),
        features: b.features.as_ptr(),
        feature_bytes: b.features.len(),
        text: b.text.as_ptr(),
        text_bytes: b.text.len(),
    };
    0
}
/// # Safety
/// batch must be live. Returned error bytes expire on free.
#[no_mangle]
pub unsafe extern "C" fn battle_transport_error_v1(
    batch: *const Batch,
    len: *mut usize,
) -> *const u8 {
    if batch.is_null() || len.is_null() {
        return std::ptr::null();
    }
    let batch = &*batch;
    *len = batch.error.len();
    batch.error.as_ptr()
}
/// # Safety
/// batch must be null or a returned batch not previously freed.
#[no_mangle]
pub unsafe extern "C" fn battle_transport_free_v1(batch: *mut Batch) {
    if !batch.is_null() {
        drop(Box::from_raw(batch));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ordinary_feature_strings_borrow_the_response() {
        let input = br#""AAAA""#;
        let parsed: Features = serde_json::from_slice(input).unwrap();
        match parsed {
            Features::Packed(Cow::Borrowed(value)) => {
                assert_eq!(value, "AAAA");
                assert_eq!(value.as_ptr(), input[1..].as_ptr());
            }
            _ => panic!("unescaped feature strings must not allocate"),
        }
    }

    #[test]
    fn escaped_feature_strings_and_legacy_arrays_still_decode() {
        let escaped: Features = serde_json::from_slice(br#""\u0041AA=""#).unwrap();
        let mut buffer = Vec::new();
        features(&mut buffer, escaped, true, 1).unwrap();
        assert_eq!(buffer, [0, 0]);
        let values: Features = serde_json::from_slice(b"[1099511627776,-1]").unwrap();
        features(&mut buffer, values, false, 2).unwrap();
        assert_eq!(&buffer[buffer.len() - 8..], &(-1_i64).to_le_bytes());
    }
}

// Python owns the returned bytes and row objects; native buffers cannot outlive
// their owner. I/O and decoding run detached from the Python interpreter.
use pyo3::{
    exceptions::{PyRuntimeError, PyTimeoutError},
    prelude::*,
    types::PyBytes,
};

#[pyclass(name = "SnapshotRow", module = "battle_search", frozen, get_all)]
struct PythonRow {
    handle: u64,
    player_mask: u64,
    enemy_mask: u64,
    turn: u64,
    terminal: bool,
    done: bool,
    terminal_return: Option<i64>,
    player_popular: bool,
    enemy_popular: bool,
    feature_kind: u64,
    player_features: (u64, u64),
    enemy_features: (u64, u64),
    player_hash: String,
    enemy_hash: String,
    request: String,
    divergence: Option<String>,
}

fn python_batch<'py>(
    py: Python<'py>,
    work: impl FnOnce() -> Result<Batch> + Send,
) -> PyResult<(Bound<'py, PyBytes>, Vec<PythonRow>)> {
    let batch = py
        .detach(|| catch_unwind(AssertUnwindSafe(work)))
        .map_err(|_| PyRuntimeError::new_err("native transport panic"))?
        .map_err(|error| {
            if error.code == 2 {
                PyTimeoutError::new_err(error.message)
            } else {
                PyRuntimeError::new_err(error.message)
            }
        })?;
    let string = |span: &Span| -> PyResult<String> {
        std::str::from_utf8(&batch.text[span.offset as usize..(span.offset + span.len) as usize])
            .map(str::to_owned)
            .map_err(|e| PyRuntimeError::new_err(e.to_string()))
    };
    let rows = batch
        .rows
        .iter()
        .map(|r| {
            Ok(PythonRow {
                handle: r.handle,
                player_mask: r.player_mask,
                enemy_mask: r.enemy_mask,
                turn: r.turn,
                terminal: r.terminal != 0,
                done: r.done != 0,
                terminal_return: (r.has_return != 0).then_some(r.terminal_return),
                player_popular: r.player_popular != 0,
                enemy_popular: r.enemy_popular != 0,
                feature_kind: r.feature_kind,
                player_features: (r.player_features.offset, r.player_features.len),
                enemy_features: (r.enemy_features.offset, r.enemy_features.len),
                player_hash: string(&r.player_hash)?,
                enemy_hash: string(&r.enemy_hash)?,
                request: string(&r.request)?,
                divergence: if r.has_divergence != 0 {
                    Some(string(&r.divergence)?)
                } else {
                    None
                },
            })
        })
        .collect::<PyResult<Vec<_>>>()?;
    Ok((PyBytes::new(py, &batch.features), rows))
}

#[pyfunction(name = "decode")]
fn python_decode<'py>(
    py: Python<'py>,
    data: &[u8],
    request_id: u64,
    count: usize,
    feature_count: usize,
) -> PyResult<(Bound<'py, PyBytes>, Vec<PythonRow>)> {
    python_batch(py, || decode(data, request_id, count, feature_count))
}

#[pyfunction(name = "batch")]
#[allow(clippy::too_many_arguments)]
fn python_exchange<'py>(
    py: Python<'py>,
    input_fd: i32,
    output_fd: i32,
    request_id: u64,
    episode: bool,
    requests: Vec<(u64, u64, u64, u64)>,
    feature_count: usize,
    timeout: f64,
) -> PyResult<(Bound<'py, PyBytes>, Vec<PythonRow>)> {
    python_batch(py, || {
        let rows: Vec<_> = requests
            .into_iter()
            .map(|(handle, player, enemy, seed)| Request {
                handle,
                player,
                enemy,
                seed,
            })
            .collect();
        request(
            input_fd,
            output_fd,
            request_id,
            episode,
            &rows,
            feature_count,
            timeout,
        )
    })
}

pub(crate) fn register_python(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("TRANSPORT_API_VERSION", 1)?;
    m.add_class::<PythonRow>()?;
    m.add_function(wrap_pyfunction!(python_decode, m)?)?;
    m.add_function(wrap_pyfunction!(python_exchange, m)?)?;
    Ok(())
}
