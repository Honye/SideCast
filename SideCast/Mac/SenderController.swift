//
//  SenderController.swift
//  SideCast
//
//  Top-level state for the Mac (sender) side.
//

#if os(macOS)
import Foundation
import Observation
import os

@Observable
final class SenderController {
    func start() {
        Log.app.info("Sender started")
    }

    func stop() {
        Log.app.info("Sender stopped")
    }
}
#endif
