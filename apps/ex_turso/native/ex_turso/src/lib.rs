//! Rustler NIF bindings for the `turso` crate (local SQLite-compatible engine).
//!
//! The async `turso` API is driven from a single global Tokio runtime. Database
//! and connection handles are handed back to the BEAM as `ResourceArc`s wrapping
//! a `Mutex`, so their lifetimes are managed by the Erlang garbage collector.

use once_cell::sync::Lazy;
use rustler::{Atom, Encoder, Env, ResourceArc, Term};
use std::collections::HashMap;
use std::sync::Mutex;
use tokio::runtime::Runtime;
use turso::{Builder, Connection, Database, Value};

mod atoms {
    rustler::atoms! {
        ok,
        busy,
        constraint,
        io,
        corrupt,
        misuse,
        invalid_param,
        error,
        blob,
    }
}

/// Errors cross the NIF boundary as `{code, message}` so the Elixir side can
/// route on the class (e.g. disconnect on `:io`/`:corrupt`, retry on `:busy`).
type NifError = (Atom, String);

/// Map a `turso::Error` onto a coarse error class atom plus its message.
fn classify(err: turso::Error) -> NifError {
    use turso::Error::*;
    let code = match &err {
        Busy(_) | BusySnapshot(_) => atoms::busy(),
        Constraint(_) => atoms::constraint(),
        IoError(..) => atoms::io(),
        Corrupt(_) | NotAdb(_) => atoms::corrupt(),
        Misuse(_) => atoms::misuse(),
        _ => atoms::error(),
    };
    (code, err.to_string())
}

/// Wrap a non-turso error (e.g. mutex poisoning) as a generic `:error`.
fn internal_error(err: impl std::fmt::Display) -> NifError {
    (atoms::error(), err.to_string())
}

/// Global multi-threaded Tokio runtime used to drive turso's async API.
static RT: Lazy<Runtime> = Lazy::new(|| Runtime::new().expect("failed to start Tokio runtime"));

/// Resource wrapping an open `turso::Database`.
struct DbResource {
    inner: Mutex<Option<Database>>,
}

#[rustler::resource_impl]
impl rustler::Resource for DbResource {}

/// Resource wrapping a `turso::Connection`.
struct ConnResource {
    inner: Mutex<Option<Connection>>,
}

#[rustler::resource_impl]
impl rustler::Resource for ConnResource {}

/// Resource wrapping an open `turso::sync::Database`.
struct SyncDbResource {
    inner: Mutex<Option<turso::sync::Database>>,
}

#[rustler::resource_impl]
impl rustler::Resource for SyncDbResource {}

/// A decoded SQL value ready to be encoded back into an Elixir term.
enum SqlValue {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
    Blob(Vec<u8>),
}

impl Encoder for SqlValue {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            SqlValue::Null => rustler::types::atom::nil().encode(env),
            SqlValue::Integer(i) => i.encode(env),
            SqlValue::Real(f) => f.encode(env),
            SqlValue::Text(s) => s.encode(env),
            SqlValue::Blob(bytes) => {
                let mut bin = rustler::OwnedBinary::new(bytes.len())
                    .expect("failed to allocate binary for blob");
                bin.as_mut_slice().copy_from_slice(bytes);
                bin.release(env).encode(env)
            }
        }
    }
}

impl From<Value> for SqlValue {
    fn from(value: Value) -> Self {
        match value {
            Value::Null => SqlValue::Null,
            Value::Integer(i) => SqlValue::Integer(i),
            Value::Real(f) => SqlValue::Real(f),
            Value::Text(s) => SqlValue::Text(s),
            Value::Blob(b) => SqlValue::Blob(b),
        }
    }
}

/// Decode an Elixir term into a `turso::Value` for use as a bound parameter.
///
/// Integers and floats map to `Integer`/`Real`, UTF-8 binaries to `Text`,
/// other binaries to `Blob`, `nil` to `Null`, and `true`/`false` to `1`/`0`.
/// Any other term is rejected so unsupported parameters fail loudly instead
/// of silently binding `NULL`.
fn term_to_value(term: &Term, index: usize) -> Result<Value, NifError> {
    if let Ok((tag, bin)) = term.decode::<(Atom, rustler::Binary)>() {
        if tag == atoms::blob() {
            return Ok(Value::Blob(bin.as_slice().to_vec()));
        }
    }

    if let Ok(name) = term.atom_to_string() {
        return match name.as_str() {
            "nil" => Ok(Value::Null),
            "true" => Ok(Value::Integer(1)),
            "false" => Ok(Value::Integer(0)),
            other => Err((
                atoms::invalid_param(),
                format!("unsupported parameter at index {index}: atom :{other}"),
            )),
        };
    }

    if let Ok(i) = term.decode::<i64>() {
        Ok(Value::Integer(i))
    } else if let Ok(f) = term.decode::<f64>() {
        Ok(Value::Real(f))
    } else if let Ok(s) = term.decode::<String>() {
        Ok(Value::Text(s))
    } else if let Ok(bin) = term.decode::<rustler::Binary>() {
        Ok(Value::Blob(bin.as_slice().to_vec()))
    } else {
        Err((
            atoms::invalid_param(),
            format!(
                "unsupported parameter at index {index}: \
                 expected an integer (i64 range), float, binary, boolean, or nil"
            ),
        ))
    }
}

fn decode_params(params: &[Term]) -> Result<Vec<Value>, NifError> {
    params
        .iter()
        .enumerate()
        .map(|(index, term)| term_to_value(term, index))
        .collect()
}

fn fetch_rows(
    conn: ResourceArc<ConnResource>,
    sql: String,
    values: Vec<Value>,
) -> Result<(Vec<String>, Vec<Vec<SqlValue>>), NifError> {
    let guard = conn.inner.lock().map_err(internal_error)?;
    let conn = guard
        .as_ref()
        .ok_or_else(|| internal_error("connection is closed"))?;

    RT.block_on(async {
        let mut rows = conn.query(&sql, values).await.map_err(classify)?;
        let columns = rows.column_names();
        let mut acc = Vec::new();

        while let Some(row) = rows.next().await.map_err(classify)? {
            let mut values = Vec::with_capacity(columns.len());
            for idx in 0..columns.len() {
                let value = row.get_value(idx).map_err(classify)?;
                values.push(SqlValue::from(value));
            }
            acc.push(values);
        }

        Ok::<_, NifError>((columns, acc))
    })
}

/// Open (or create) a local database file at `path`. `":memory:"` is supported.
#[rustler::nif(schedule = "DirtyIo")]
fn open(path: String) -> Result<ResourceArc<DbResource>, NifError> {
    let result = RT.block_on(async {
        Builder::new_local(&path)
            .experimental_index_method(true)
            .build()
            .await
    });
    match result {
        Ok(db) => Ok(ResourceArc::new(DbResource {
            inner: Mutex::new(Some(db)),
        })),
        Err(e) => Err(classify(e)),
    }
}

/// Open a connection against a previously opened database.
#[rustler::nif(schedule = "DirtyIo")]
fn connect(db: ResourceArc<DbResource>) -> Result<ResourceArc<ConnResource>, NifError> {
    let guard = db.inner.lock().map_err(internal_error)?;
    let db = guard
        .as_ref()
        .ok_or_else(|| internal_error("database is closed"))?;

    match db.connect() {
        Ok(conn) => Ok(ResourceArc::new(ConnResource {
            inner: Mutex::new(Some(conn)),
        })),
        Err(e) => Err(classify(e)),
    }
}

/// Open (or create) a local database synced with a remote database.
#[rustler::nif(schedule = "DirtyIo")]
fn open_sync(
    path: String,
    remote_url: String,
    auth_token: String,
) -> Result<ResourceArc<SyncDbResource>, NifError> {
    let result = RT.block_on(async {
        turso::sync::Builder::new_remote(&path)
            .with_remote_url(&remote_url)
            .with_auth_token(&auth_token)
            .build()
            .await
    });
    match result {
        Ok(db) => Ok(ResourceArc::new(SyncDbResource {
            inner: Mutex::new(Some(db)),
        })),
        Err(e) => Err(classify(e)),
    }
}

/// Open a connection against a synced database.
#[rustler::nif(schedule = "DirtyIo")]
fn connect_sync(db: ResourceArc<SyncDbResource>) -> Result<ResourceArc<ConnResource>, NifError> {
    let db_clone = {
        let guard = db.inner.lock().map_err(internal_error)?;
        guard
            .as_ref()
            .ok_or_else(|| internal_error("database is closed"))?
            .clone()
    };
    let conn = RT.block_on(async { db_clone.connect().await.map_err(classify) })?;
    Ok(ResourceArc::new(ConnResource {
        inner: Mutex::new(Some(conn)),
    }))
}

/// Run bidirectional sync.
#[rustler::nif(schedule = "DirtyIo")]
fn sync(db: ResourceArc<SyncDbResource>) -> Result<Atom, NifError> {
    let db_clone = {
        let guard = db.inner.lock().map_err(internal_error)?;
        guard
            .as_ref()
            .ok_or_else(|| internal_error("database is closed"))?
            .clone()
    };
    RT.block_on(async {
        db_clone.pull().await.map_err(classify)?;
        db_clone.push().await.map_err(classify)?;
        Ok::<(), NifError>(())
    })?;
    Ok(atoms::ok())
}

/// Run a query and return its rows as a list of maps keyed by column name.
#[rustler::nif(schedule = "DirtyIo")]
fn query<'a>(
    env: Env<'a>,
    conn: ResourceArc<ConnResource>,
    sql: String,
    params: Vec<Term<'a>>,
) -> Result<Term<'a>, NifError> {
    let values = decode_params(&params)?;
    let (columns, rows) = fetch_rows(conn, sql, values)?;

    let rows: Vec<HashMap<String, SqlValue>> = rows
        .into_iter()
        .map(|row| columns.iter().cloned().zip(row).collect())
        .collect();

    Ok(rows.encode(env))
}

/// Run a query and return ordered column names plus ordered row values.
#[rustler::nif(schedule = "DirtyIo")]
fn query_rows<'a>(
    conn: ResourceArc<ConnResource>,
    sql: String,
    params: Vec<Term<'a>>,
) -> Result<(Vec<String>, Vec<Vec<SqlValue>>), NifError> {
    let values = decode_params(&params)?;
    fetch_rows(conn, sql, values)
}

/// Execute a statement and return the number of affected rows.
#[rustler::nif(schedule = "DirtyIo")]
fn execute<'a>(
    conn: ResourceArc<ConnResource>,
    sql: String,
    params: Vec<Term<'a>>,
) -> Result<u64, NifError> {
    let values = decode_params(&params)?;
    let guard = conn.inner.lock().map_err(internal_error)?;
    let conn = guard
        .as_ref()
        .ok_or_else(|| internal_error("connection is closed"))?;

    RT.block_on(async { conn.execute(&sql, values).await.map_err(classify) })
}

/// Close a connection. turso closes the underlying connection when the resource
/// is dropped, so this releases held buffers best-effort and returns `:ok`.
#[rustler::nif(schedule = "DirtyIo")]
fn close(conn: ResourceArc<ConnResource>) -> rustler::types::atom::Atom {
    if let Ok(mut guard) = conn.inner.lock() {
        if let Some(conn) = guard.take() {
            let _ = conn.cacheflush();
        }
    }
    atoms::ok()
}

/// Close a local database handle by dropping the resource contents eagerly.
#[rustler::nif(schedule = "DirtyIo")]
fn close_db(db: ResourceArc<DbResource>) -> rustler::types::atom::Atom {
    if let Ok(mut guard) = db.inner.lock() {
        let _ = guard.take();
    }
    atoms::ok()
}

/// Close a synced database handle by dropping the resource contents eagerly.
#[rustler::nif(schedule = "DirtyIo")]
fn close_sync_db(db: ResourceArc<SyncDbResource>) -> rustler::types::atom::Atom {
    if let Ok(mut guard) = db.inner.lock() {
        let _ = guard.take();
    }
    atoms::ok()
}

rustler::init!("Elixir.Turso.Native");
