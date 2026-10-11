# Rust owns the macOS database and library

Date: 2026-10-11

The owner requested moving database and library management to Rust, preserving
all library data and the current SwiftUI interface and animations.

## Platform boundary

`DatabaseManager` remains the interface used by application managers and views.
Xcode target membership selects `Core/LibraryStorage` on macOS and the existing
`Managers/Database` implementation on iOS. Shared callers request full records
through this interface instead of reaching into a GRDB connection.

On macOS the UniFFI `LibraryDatabase` object owns system SQLite connections,
migrations, read snapshots, writer transactions, queries and mutations. Reads
reuse independent WAL connections, so importing tracks does not serialize UI
reads behind the writer. The writer uses immediate transactions, foreign keys,
a five-second busy timeout and NORMAL synchronous mode.

Rust owns entity normalization, aliases, duplicate selection, folder relocation,
scan update decisions and persistence. Swift supplies Apple filesystem and
security-scoped bookmark observations, metadata-engine results and prepared
image bytes. Swift also owns async progress, localization, notifications and
observable publication. No UI or animation implementation moves to Rust.

GRDB remains linked for existing value/model decoders. Track lists cross FFI as
typed lightweight records and initialize Swift models directly; dates retain the
existing GRDB value decoder. Other records use typed SQLite cells and a converter
that constructs a GRDB Row without opening a connection. Artwork is fetched only
when requested and shared by album within each result. Rust domain methods execute
closed operations; callers cannot send arbitrary SQL across the bridge.

## Existing data

The existing bundle-specific database file is opened in place. No model
reserialization, audio reimport, new database fallback or schema replacement is
part of the cutover. Historical migration identifiers and raw stored values
remain valid. Dates retain GRDB's UTC text representation. macOS absolute paths,
iOS relative paths and opaque Apple bookmark bytes retain their existing roles.

Migrations and library mutations fail without resetting data. Resuming the old
artist-association job cannot erase already processed associations. Import item
failures roll back their partial writes. Lyrics and metadata updates touch their
intended fields rather than saving a stale full record over favorite/play state.
Ordinary cleanup retains orphan entities carrying database-only artwork, user
metadata or aliases, even though this can retain dormant rows on disk. A retained
alias without remaining role references resolves during reimport; referenced
artists keep role-specific matching. Each transaction snapshots artist policy so
independent database owners cannot replace one another's role lookup.

New genre creation records its inserted ID before linking the track. This fixes
the previous first-scan omission; no genre links are rewritten merely by opening
the existing database.

## Evidence required for delivery

Use SQLite backups and compare every stored value, storage type and BLOB before
and after opening the same current database. Exercise migrations, rollback,
scan/refresh, normalized relationships, playlists and journal replay on disposable
copies. Measure actual Swift callers through generated bindings, including FFI
and row decoding. Build both targets, run required CI, then install the tested
signed binary with a fresh rollback backup and verify the user's library.
