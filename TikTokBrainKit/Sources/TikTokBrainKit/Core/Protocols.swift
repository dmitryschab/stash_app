// Protocols.swift
import Foundation

public protocol Enriching: Sendable { func enrich(_ url: URL) async throws -> VideoMeta }
public protocol MediaFetching: Sendable { func fetch(streamURL: URL) async throws -> MediaBundle }
public protocol Transcribing: Sendable { func transcribe(audioFileURL: URL) async throws -> String }
public protocol Analyzing: Sendable {
    func analyze(meta: VideoMeta, transcript: String?, ocrText: String?) async throws -> Analysis
}
public protocol MusicLinkResolving: Sendable {
    func universalLink(title: String, artist: String) async throws -> URL?
}
