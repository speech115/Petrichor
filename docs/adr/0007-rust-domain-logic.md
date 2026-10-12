# macOS domain logic in Rust, SwiftUI presentation

Date: 2026-10-11

The owner requested moving macOS application logic to Rust while retaining the
current SwiftUI interface and Apple animations. ADR-0006's metadata library is
extended through the same UniFFI package; no second runtime or UI framework is
introduced. iOS continues to use Swift implementations.

## Boundary

The additional domain-logic seam consists of these existing public Swift entry
points and narrow policy adapters in `Core/`:

| Swift entry point | macOS Rust implementation |
| --- | --- |
| `ArtistParser` | normalization, known-name and alias resolution, parsing caches |
| `M3UTrackResolver`, `M3UPlaylistCodec` | path variants, filename keys, ambiguity policy, playlist text and naming |
| `LyricsParser` | LRC/SRT timestamps, line order and timing windows |
| `FilenameMetadataFallback` | filename-derived artist/title policy |
| `QueuePolicy` | repeat navigation, queue edit validation/cursors, playable candidate order |
| `LibraryQueryPolicy` | FTS expressions and parameterized smart-playlist predicates/sorting |

Only these seam implementations select the macOS Rust backend with conditional
compilation. Their callers use the same interfaces on both platforms. The
remaining Swift branches are the active iOS implementations, not a macOS
compatibility fallback. `Models/Core/Lyrics.swift` continues to own Swift model
identities; parsing is delegated to the seam.

## Responsibilities retained in Swift

SwiftUI views, animation timing and observable state publication stay in Swift.
So do Apple framework adapters, security-scoped URL access, localized calendar
boundaries, file encoding detection and system media integration. Crescendo
still performs macOS audio playback, decoding and effects; this change does not
replace it with a Rust decoder.

GRDB retains ownership of database connections, migrations, transactions,
record decoding and persistence orchestration. Rust returns SQL with bound
arguments and whitelisted columns; it does not open a second connection inside
an existing transaction. Dates return as typed timestamps and Swift binds them
using GRDB's existing Date representation. Artwork processing remains with
the platform image implementation.

This is a domain-logic migration, not a claim that every non-view Swift file or
every database operation has been rewritten in Rust.

## Compatibility and evidence

The original Swift implementations are the behavioral reference. Paired evals
must compare real Swift callers through generated UniFFI bindings, including
conversion overhead, rather than benchmark only internal Rust functions.
Filename/artist comparisons include the local library and Unicode cases;
queue evals include duplicate identities, empty queues and cursor boundaries;
query evals compare selected rows, including NULL and negated criteria.

Production library data is copied with SQLite backup for local evals. It is not
checked into the repository and is never rebuilt from audio files. UI evidence
uses separately identified evaluation applications and an identical snapshot.
Compilation, parity tests, timings and visual checks are reported separately.

## FFI hot paths

Swift keeps a memo of already-lifted artist results so cache hits do not serialize
strings and allocate the same array through UniFFI again. Parsing, normalization,
alias resolution and lookup state remain in Rust. One Swift lock covers memo hits,
misses and all Rust lookup mutations; a lookup change invalidates the parse memo
before another caller can read it. Normalized values do not depend on lookup state.
The Rust caches still serve computations within the domain; the bridge memo also
retains Swift values. `Scripts/check-artist-bridge.sh` checks invalidation and
concurrent mutations through real generated bindings on macOS CI.

Query construction retains one lifted static predicate, keyed by all rules and
match type. It caches no selected rows; GRDB always executes against current data.
Rules using dateAdded/lastPlayedDate bypass this memo so clock/calendar-dependent
bounds are rebuilt. Queue storage stays in Swift: the adapter finds the first
matching Track identity and sends count, cursor and existing index (-1 if absent)
as scalars. Rust validates those positions and decides replacement, deduplication
and cursor movement; the full ID array no longer crosses FFI for each edit.
