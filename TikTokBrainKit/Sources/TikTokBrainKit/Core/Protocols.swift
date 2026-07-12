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
public protocol MusicLinkResolving: Sendable {
    func universalLink(title: String, artist: String) async throws -> URL?
}
