// Protocols.swift
import Foundation

public protocol Enriching: Sendable { func enrich(_ url: URL) async throws -> VideoMeta }
public protocol MediaFetching: Sendable { func fetch(streamURL: URL) async throws -> MediaBundle }
/// Cloud transcription: the box downloads the video's audio itself (TikTok blocks
/// all in-app media downloads) and returns filtered text — nil means music/no-speech.
public protocol Transcribing: Sendable { func transcript(for videoURL: URL) async throws -> String? }
public protocol Analyzing: Sendable {
    func analyze(meta: VideoMeta, transcript: String?, ocrText: String?) async throws -> Analysis
}
/// Resolves the releases a video named to streaming links, leaving `link` nil on any it cannot
/// match confidently. Takes the whole list rather than one title at a time: a video recommending
/// five albums is one unit of work, and the implementation paces its own lookups.
public protocol MusicLinkResolving: Sendable {
    func resolve(_ picks: [MusicPick]) async -> [MusicPick]
}
