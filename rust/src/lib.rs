//! Petrichor's Rust core for the macOS app, exposed to Swift through UniFFI.
//!
//! Today it holds one seam implementation: reading a file's tags and audio
//! properties (`read_tags`). Swift maps the result onto `TrackMetadata`.

use lofty::config::ParseOptions;
use lofty::file::FileType;
use lofty::id3::v2::{Frame, FrameId};
use lofty::mp4::{Mp4Codec, Mp4File};
use lofty::mpeg::MpegFile;
use lofty::picture::PictureType;
use lofty::prelude::*;
use lofty::tag::Tag;

uniffi::setup_scaffolding!();

/// Raw tag values as stored in the file. Normalization the app already does
/// in Swift (year from a date, artwork compression, filename fallback) stays
/// there.
#[derive(uniffi::Record, Default)]
pub struct AudioTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub composer: Option<String>,
    pub genre: Option<String>,
    /// Recording date as written (`2011`, `1976-08-25`); ID3v2.3 TYER is
    /// upgraded to TDRC by lofty, so both land here.
    pub recording_date: Option<String>,
    pub original_release_date: Option<String>,
    pub track_number: Option<u32>,
    pub total_tracks: Option<u32>,
    pub disc_number: Option<u32>,
    pub total_discs: Option<u32>,
    pub bpm: Option<u32>,
    pub compilation: bool,
    pub sort_title: Option<String>,
    pub sort_artist: Option<String>,
    pub sort_album: Option<String>,
    pub sort_album_artist: Option<String>,
    /// Front cover if present, otherwise the first embedded picture.
    pub artwork: Option<Vec<u8>>,
    pub extended: ExtendedTags,

    pub duration_seconds: f64,
    /// kbps
    pub bitrate: Option<u32>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u32>,
    pub bit_depth: Option<u32>,
    pub codec: String,
}

/// The fields behind `ExtendedMetadata`.
#[derive(uniffi::Record, Default)]
pub struct ExtendedTags {
    pub isrc: Option<String>,
    pub catalog_number: Option<String>,
    pub musicbrainz_artist_id: Option<String>,
    pub musicbrainz_album_id: Option<String>,
    pub musicbrainz_album_artist_id: Option<String>,
    pub musicbrainz_track_id: Option<String>,
    pub musicbrainz_release_group_id: Option<String>,
    pub musicbrainz_work_id: Option<String>,
    pub acoustid: Option<String>,
    pub acoustid_fingerprint: Option<String>,
    pub original_artist: Option<String>,
    pub producer: Option<String>,
    pub engineer: Option<String>,
    pub lyricist: Option<String>,
    pub conductor: Option<String>,
    pub remixer: Option<String>,
    /// ID3 has one frame (TPUB) for label and publisher; it lands here.
    pub label: Option<String>,
    pub copyright: Option<String>,
    pub key: Option<String>,
    pub mood: Option<String>,
    pub language: Option<String>,
    pub lyrics: Option<String>,
    pub comment: Option<String>,
    pub subtitle: Option<String>,
    pub grouping: Option<String>,
    pub movement: Option<String>,
    pub encoded_by: Option<String>,
    pub encoder_settings: Option<String>,
    pub sort_composer: Option<String>,
    /// dB
    pub replay_gain_track: Option<f64>,
    pub replay_gain_album: Option<f64>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ReadError {
    #[error("{message}")]
    Unreadable { message: String },
}

/// Extensions `read_tags` understands (lofty's `FileType::from_ext`).
#[uniffi::export]
pub fn supported_extensions() -> Vec<String> {
    [
        "aac", "ape", "aiff", "aif", "afc", "aifc", "mp3", "mp2", "mp1", "wav", "wave", "wv",
        "opus", "flac", "ogg", "mp4", "m4a", "m4b", "m4p", "m4r", "m4v", "3gp", "mpc", "mp+",
        "mpp", "spx",
    ]
    .map(String::from)
    .to_vec()
}

/// Reads tags and audio properties. A file without any tag is not an error:
/// it comes back with every tag field empty and the audio properties filled.
#[uniffi::export]
pub fn read_tags(path: String) -> Result<AudioTags, ReadError> {
    let file = lofty::read_from_path(&path).map_err(|error| ReadError::Unreadable {
        message: error.to_string(),
    })?;

    let properties = file.properties();
    let mut tags = AudioTags {
        duration_seconds: properties.duration().as_secs_f64(),
        bitrate: properties.audio_bitrate().filter(|&kbps| kbps > 0),
        sample_rate: properties.sample_rate().filter(|&hz| hz > 0),
        channels: properties
            .channels()
            .map(u32::from)
            .filter(|&count| count > 0),
        bit_depth: properties.bit_depth().map(u32::from),
        codec: codec_name(file.file_type(), &path).to_string(),
        ..AudioTags::default()
    };

    // Primary tag (ID3v2 for MP3) first; the others (ID3v1, APE) only fill
    // what it lacks, as TagLib does.
    let primary = file.primary_tag_type();
    if let Some(tag) = file.primary_tag() {
        fill(&mut tags, tag);
    }
    if file.file_type() == FileType::Mpeg {
        id3v2_extras(&mut tags, &path);
    }
    for tag in file.tags().iter().filter(|tag| tag.tag_type() != primary) {
        fill(&mut tags, tag);
    }
    Ok(tags)
}

/// ID3v2 frames lofty's generic `Tag` loses, read straight from the frames:
/// - a full-date TDRC (`1976-08-25`) in an ID3v2.3 tag: lofty 0.25's
///   TYER→TDRC conversion removes it and returns early without putting it
///   back. ponytail: drop once lofty keeps the frame.
/// - `TXXX:comment`, where FFmpeg/yt-dlp write the full comment; COMM in
///   those files often holds a copy of the 28-char ID3v1 one. It wins over
///   COMM, as it does in FFmpeg.
fn id3v2_extras(tags: &mut AudioTags, path: &str) {
    let Ok(mut file) = std::fs::File::open(path) else {
        return;
    };
    let options = ParseOptions::new()
        .read_properties(false)
        .implicit_conversions(false);
    let Ok(mpeg) = MpegFile::read_from(&mut file, options) else {
        return;
    };
    let Some(id3v2) = mpeg.id3v2() else {
        return;
    };
    if tags.recording_date.is_none() {
        tags.recording_date = match id3v2.get(&FrameId::Valid("TDRC".into())) {
            Some(Frame::Timestamp(frame)) => Some(frame.timestamp.to_string()),
            Some(Frame::Text(frame)) => non_empty(&frame.value),
            _ => None,
        };
    }
    if let Some(comment) = id3v2.get_user_text("comment").and_then(non_empty) {
        tags.extended.comment = Some(comment);
    }
}

fn non_empty(value: &str) -> Option<String> {
    Some(value.trim().to_string()).filter(|s| !s.is_empty())
}

/// Sets only the fields still empty, so earlier tags win.
fn fill(tags: &mut AudioTags, tag: &Tag) {
    fn keep<T>(slot: &mut Option<T>, value: impl FnOnce() -> Option<T>) {
        if slot.is_none() {
            *slot = value();
        }
    }
    let text = |key: ItemKey| {
        tag.get_string(key)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(String::from)
    };
    let gain = |key: ItemKey| {
        text(key).and_then(|value| {
            value
                .trim_end_matches(|c: char| c.is_alphabetic() || c.is_whitespace())
                .parse::<f64>()
                .ok()
        })
    };

    keep(&mut tags.title, || text(ItemKey::TrackTitle));
    keep(&mut tags.artist, || text(ItemKey::TrackArtist));
    keep(&mut tags.album, || text(ItemKey::AlbumTitle));
    keep(&mut tags.album_artist, || text(ItemKey::AlbumArtist));
    keep(&mut tags.composer, || text(ItemKey::Composer));
    keep(&mut tags.genre, || text(ItemKey::Genre));
    keep(&mut tags.recording_date, || {
        text(ItemKey::RecordingDate).or_else(|| text(ItemKey::Year))
    });
    keep(&mut tags.original_release_date, || {
        text(ItemKey::OriginalReleaseDate)
    });
    keep(&mut tags.track_number, || tag.track().filter(|&n| n > 0));
    keep(&mut tags.total_tracks, || {
        tag.track_total().filter(|&n| n > 0)
    });
    keep(&mut tags.disc_number, || tag.disk().filter(|&n| n > 0));
    keep(&mut tags.total_discs, || {
        tag.disk_total().filter(|&n| n > 0)
    });
    keep(&mut tags.bpm, || {
        text(ItemKey::IntegerBpm)
            .or_else(|| text(ItemKey::Bpm))
            .and_then(|bpm| bpm.parse::<f64>().ok())
            .filter(|bpm| *bpm > 0.0)
            .map(|bpm| bpm.round() as u32)
    });
    tags.compilation |= text(ItemKey::FlagCompilation).is_some_and(|flag| flag == "1");
    keep(&mut tags.sort_title, || text(ItemKey::TrackTitleSortOrder));
    keep(&mut tags.sort_artist, || {
        text(ItemKey::TrackArtistSortOrder)
    });
    keep(&mut tags.sort_album, || text(ItemKey::AlbumTitleSortOrder));
    keep(&mut tags.sort_album_artist, || {
        text(ItemKey::AlbumArtistSortOrder)
    });

    let pictures = tag.pictures();
    keep(&mut tags.artwork, || {
        pictures
            .iter()
            .find(|picture| picture.pic_type() == PictureType::CoverFront)
            .or_else(|| pictures.first())
            .map(|picture| picture.data().to_vec())
    });

    let ext = &mut tags.extended;
    keep(&mut ext.isrc, || text(ItemKey::Isrc));
    keep(&mut ext.catalog_number, || text(ItemKey::CatalogNumber));
    keep(&mut ext.musicbrainz_artist_id, || {
        text(ItemKey::MusicBrainzArtistId)
    });
    keep(&mut ext.musicbrainz_album_id, || {
        text(ItemKey::MusicBrainzReleaseId)
    });
    keep(&mut ext.musicbrainz_album_artist_id, || {
        text(ItemKey::MusicBrainzReleaseArtistId)
    });
    keep(&mut ext.musicbrainz_track_id, || {
        text(ItemKey::MusicBrainzRecordingId)
    });
    keep(&mut ext.musicbrainz_release_group_id, || {
        text(ItemKey::MusicBrainzReleaseGroupId)
    });
    keep(&mut ext.musicbrainz_work_id, || {
        text(ItemKey::MusicBrainzWorkId)
    });
    keep(&mut ext.acoustid, || text(ItemKey::AcoustId));
    keep(&mut ext.acoustid_fingerprint, || {
        text(ItemKey::AcoustIdFingerprint)
    });
    keep(&mut ext.original_artist, || text(ItemKey::OriginalArtist));
    keep(&mut ext.producer, || text(ItemKey::Producer));
    keep(&mut ext.engineer, || text(ItemKey::Engineer));
    keep(&mut ext.lyricist, || text(ItemKey::Lyricist));
    keep(&mut ext.conductor, || text(ItemKey::Conductor));
    keep(&mut ext.remixer, || text(ItemKey::Remixer));
    keep(&mut ext.label, || {
        text(ItemKey::Label).or_else(|| text(ItemKey::Publisher))
    });
    keep(&mut ext.copyright, || text(ItemKey::CopyrightMessage));
    keep(&mut ext.key, || text(ItemKey::InitialKey));
    keep(&mut ext.mood, || text(ItemKey::Mood));
    keep(&mut ext.language, || text(ItemKey::Language));
    keep(&mut ext.lyrics, || {
        text(ItemKey::Lyrics).or_else(|| text(ItemKey::UnsyncLyrics))
    });
    keep(&mut ext.comment, || text(ItemKey::Comment));
    keep(&mut ext.subtitle, || text(ItemKey::TrackSubtitle));
    keep(&mut ext.grouping, || {
        text(ItemKey::ContentGroup).or_else(|| text(ItemKey::AppleId3v2ContentGroup))
    });
    keep(&mut ext.movement, || text(ItemKey::Movement));
    keep(&mut ext.encoded_by, || text(ItemKey::EncodedBy));
    keep(&mut ext.encoder_settings, || {
        text(ItemKey::EncoderSettings).or_else(|| text(ItemKey::EncoderSoftware))
    });
    keep(&mut ext.sort_composer, || text(ItemKey::ComposerSortOrder));
    keep(&mut ext.replay_gain_track, || {
        gain(ItemKey::ReplayGainTrackGain)
    });
    keep(&mut ext.replay_gain_album, || {
        gain(ItemKey::ReplayGainAlbumGain)
    });
}

/// Codec names match what the Swift side already stores (`MetadataMapping`
/// decides losslessness from them).
fn codec_name(file_type: FileType, path: &str) -> &'static str {
    match file_type {
        FileType::Mpeg => "mp3",
        FileType::Mp4 => mp4_codec(path),
        FileType::Aac => "aac",
        FileType::Flac => "flac",
        FileType::Opus => "opus",
        FileType::Vorbis => "vorbis",
        FileType::Wav => "pcm",
        FileType::Aiff => "aiff",
        FileType::Ape => "ape",
        FileType::WavPack => "wavpack",
        FileType::Mpc => "musepack",
        FileType::Speex => "speex",
        _ => "unknown",
    }
}

/// MP4 holds AAC or ALAC (or rarely MP3/FLAC); only the container's own
/// properties say which.
fn mp4_codec(path: &str) -> &'static str {
    let codec = std::fs::File::open(path).ok().and_then(|mut file| {
        let mp4 = Mp4File::read_from(&mut file, ParseOptions::new()).ok()?;
        mp4.properties().codec()
    });
    match codec {
        Some(Mp4Codec::ALAC) => "alac",
        Some(Mp4Codec::MP3) => "mp3",
        Some(Mp4Codec::FLAC) => "flac",
        _ => "aac",
    }
}

mod artists;
mod filename;
mod lyrics;
mod m3u;

mod queue;

mod query;
