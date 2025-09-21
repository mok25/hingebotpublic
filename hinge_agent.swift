import Foundation
import Dispatch
import CoreGraphics
import Security
import AVFoundation
import Vision
import AppKit
import ImageIO
import ScreenCaptureKit

// MARK: - Data Models
struct Config: Codable {
    let defaults: DefaultConfig
    let initialization: InitializationConfig
    let ui: UIConfig

    struct DefaultConfig: Codable {
        let visionProvider: String
        let scrollDelay: Double
        let duplicateDetection: Bool
        let duplicateThreshold: Float
        let markMode: Bool
        let filterMode: Bool
        let testMode: Bool
        let dumbMode: Bool
        let aestheticMode: Bool
    }

    struct InitializationConfig: Codable {
        let analysisType: String
        let userCriteria: String
        let skipSetup: Bool
    }

    struct UIConfig: Codable {
        let aestheticOutput: AestheticOutput

        struct AestheticOutput: Codable {
            let scrolling: String
            let thinking: String
            let swipingRight: String
            let swipingLeft: String
        }
    }
}

// MARK: - Global Aesthetic Mode Control
var globalIsAestheticMode = false
var globalConfig: Config?
var aestheticScrollCount = 0
var aestheticThinkCount = 0

func aestheticSafePrint(_ message: String, forceShow: Bool = false) {
    if !globalIsAestheticMode || forceShow {
        print(message)
    }
}

func showAestheticAction(_ action: String) {
    if globalIsAestheticMode, let config = globalConfig {
        switch action {
        case "scroll":
            if aestheticScrollCount < 5 {
                print(config.ui.aestheticOutput.scrolling)
                aestheticScrollCount += 1
            }
        case "think":
            if aestheticThinkCount < 1 {
                print(config.ui.aestheticOutput.thinking)
                aestheticThinkCount += 1
            }
        case "swipe_right":
            print(config.ui.aestheticOutput.swipingRight)
        case "swipe_left":
            print(config.ui.aestheticOutput.swipingLeft)
        default:
            break
        }
    }
}

func extractReasoningFromResponse(_ reasoning: String) -> String {
    // Handle JSON code block format: ```json\n{...}\n```
    if reasoning.contains("```json") {
        let pattern = #"```json\s*\n(.*?)\n```"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: reasoning, options: [], range: NSRange(reasoning.startIndex..., in: reasoning)),
           let jsonRange = Range(match.range(at: 1), in: reasoning) {
            let jsonString = String(reasoning[jsonRange])

            // Parse the extracted JSON
            if let jsonData = jsonString.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
               let extractedReasoning = jsonObject["reasoning"] as? String {
                return extractedReasoning
            }
        }
    }

    // Try to parse as direct JSON
    if let reasoningData = reasoning.data(using: .utf8),
       let jsonObject = try? JSONSerialization.jsonObject(with: reasoningData, options: []) as? [String: Any],
       let extractedReasoning = jsonObject["reasoning"] as? String {
        return extractedReasoning
    }

    // Fallback: return original string
    return reasoning
}

func showAestheticReasoning(_ reasoning: String) {
    if globalIsAestheticMode {
        let cleanReasoning = extractReasoningFromResponse(reasoning)
        print("  Reasoning: \(cleanReasoning)")
    }
}

func resetAestheticCounters() {
    aestheticScrollCount = 0
    aestheticThinkCount = 0
}

struct OCRResult {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

struct ExtractedPhoto {
    let image: NSImage
    let boundingBox: CGRect
    let filename: String
    let scrollPosition: Int
    var personDetection: PersonDetectionResult?
    var isSinglePerson: Bool = false
    var primaryPersonBoundingBox: CGRect?
}

struct ProfileData: Codable {
    let sessionId: String
    let timestamp: String
    let scrollData: [ScrollData]
    let extractedPhotos: [PhotoMetadata]
    let visionAnalysis: [String: Any]?  // Renamed from openaiAnalysis for generic vision API support
    
    enum CodingKeys: String, CodingKey {
        case sessionId, timestamp, scrollData, extractedPhotos
        case visionAnalysis
        case openaiAnalysis  // Keep for backward compatibility
    }
    
    init(sessionId: String, timestamp: String, scrollData: [ScrollData], extractedPhotos: [PhotoMetadata], visionAnalysis: [String: Any]? = nil) {
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.scrollData = scrollData
        self.extractedPhotos = extractedPhotos
        self.visionAnalysis = visionAnalysis
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        scrollData = try container.decode([ScrollData].self, forKey: .scrollData)
        extractedPhotos = try container.decode([PhotoMetadata].self, forKey: .extractedPhotos)
        
        // Handle vision analysis with backward compatibility
        if let analysisData = try container.decodeIfPresent(Data.self, forKey: .visionAnalysis) {
            visionAnalysis = try JSONSerialization.jsonObject(with: analysisData, options: []) as? [String: Any]
        } else if let analysisData = try container.decodeIfPresent(Data.self, forKey: .openaiAnalysis) {
            // Backward compatibility - migrate openaiAnalysis to visionAnalysis
            visionAnalysis = try JSONSerialization.jsonObject(with: analysisData, options: []) as? [String: Any]
        } else {
            visionAnalysis = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(scrollData, forKey: .scrollData)
        try container.encode(extractedPhotos, forKey: .extractedPhotos)
        
        if let analysis = visionAnalysis {
            let analysisData = try JSONSerialization.data(withJSONObject: analysis, options: [])
            try container.encode(analysisData, forKey: .visionAnalysis)
        }
    }
}

struct ScrollData: Codable {
    let scrollIndex: Int
    let ocrText: String
    let photoCount: Int
    let timestamp: String
}

struct PersonDetectionResult: Codable {
    let hasPerson: Bool
    let personCount: Int
    let confidence: Float
    let personBoundingBoxes: [CGRect]
}

enum DuplicateStatus: String, Codable {
    case unique, preferred, duplicate
}

struct DuplicateMatch {
    let filename: String
    let distance: Float
    let completenessScore: Float
}

struct PhotoMetadata: Codable {
    let filename: String
    let boundingBox: CGRect
    let scrollIndex: Int
    let extractedAt: String
    let personDetection: PersonDetectionResult?
    let isSinglePerson: Bool
    let primaryPersonBoundingBox: CGRect?
    let subfolder: String // "person" for single person photos, "multi_person" for multiple people, "other" for no people
    let duplicateStatus: DuplicateStatus
    let completenessScore: Float
    let duplicateOfFilename: String?
}

struct SessionInfo: Codable {
    let sessionId: String
    let startTime: String
    let profilesProcessed: Int
    let photosExtracted: Int
    let sessionFolder: String
}

struct SearchResult {
    let text: String
    let windowName: String
    let coordinates: (x: Double, y: Double, width: Double, height: Double)
}

// MARK: - Session Manager
class SessionManager {
    private let baseSessionsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("HingeAgentSessions")
    
    init() {
        createSessionsDirectoryIfNeeded()
    }
    
    private func createSessionsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: baseSessionsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Error creating sessions directory: \(error)")
        }
    }
    
    func createNewSession() -> SessionInfo {
        let sessionId = generateSessionId()
        let sessionFolder = "session_\(sessionId)"
        let sessionDirectory = baseSessionsDirectory.appendingPathComponent(sessionFolder)
        let photosDirectory = sessionDirectory.appendingPathComponent("photos")
        let personDirectory = photosDirectory.appendingPathComponent("person")
        let multiPersonDirectory = photosDirectory.appendingPathComponent("multi_person")
        let otherDirectory = photosDirectory.appendingPathComponent("other")
        
        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: personDirectory, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: multiPersonDirectory, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Error creating session directory: \(error)")
        }
        
        let sessionInfo = SessionInfo(
            sessionId: sessionId,
            startTime: ISO8601DateFormatter().string(from: Date()),
            profilesProcessed: 0,
            photosExtracted: 0,
            sessionFolder: sessionFolder
        )
        
        saveSessionInfo(sessionInfo)
        return sessionInfo
    }
    
    func getSessionDirectory(for sessionId: String) -> URL {
        return baseSessionsDirectory.appendingPathComponent("session_\(sessionId)")
    }
    
    func getPhotosDirectory(for sessionId: String) -> URL {
        return getSessionDirectory(for: sessionId).appendingPathComponent("photos")
    }
    
    private func generateSessionId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
    
    private func saveSessionInfo(_ sessionInfo: SessionInfo) {
        let sessionDirectory = getSessionDirectory(for: sessionInfo.sessionId)
        let sessionInfoPath = sessionDirectory.appendingPathComponent("session_info.json")
        
        do {
            let data = try JSONEncoder().encode(sessionInfo)
            try data.write(to: sessionInfoPath)
        } catch {
            print("Error saving session info: \(error)")
        }
    }
    
    func finalizeSession(_ sessionInfo: SessionInfo) {
        // Update session info with final stats
        saveSessionInfo(sessionInfo)
        print("Session \(sessionInfo.sessionId) finalized")
    }
    
    func saveProfileData(_ profileData: ProfileData) {
        let sessionDirectory = getSessionDirectory(for: profileData.sessionId)
        let profileDataPath = sessionDirectory.appendingPathComponent("profile_data.json")
        
        do {
            let data = try JSONEncoder().encode(profileData)
            try data.write(to: profileDataPath)
        } catch {
            print("Error saving profile data: \(error)")
        }
    }
}

// MARK: - Duplicate Detection Cache
class DuplicateDetectionCache {
    private var personPhotoHashes: [(filename: String, featurePrint: VNFeaturePrintObservation, completeness: Float)] = []
    
    func addPhoto(_ filename: String, featurePrint: VNFeaturePrintObservation, completeness: Float) {
        personPhotoHashes.append((filename: filename, featurePrint: featurePrint, completeness: completeness))
    }
    
    func findDuplicates(for featurePrint: VNFeaturePrintObservation, threshold: Float = 0.4) -> [DuplicateMatch] {
        var duplicates: [DuplicateMatch] = []
        
        for cached in personPhotoHashes {
            do {
                var distance: Float = 0
                try featurePrint.computeDistance(&distance, to: cached.featurePrint)
                
                if distance < threshold {
                    let duplicate = DuplicateMatch(
                        filename: cached.filename,
                        distance: distance,
                        completenessScore: cached.completeness
                    )
                    duplicates.append(duplicate)
                }
            } catch {
                print("Error computing feature print distance: \(error)")
            }
        }
        
        return duplicates
    }
    
    func removePhoto(filename: String) {
        personPhotoHashes.removeAll { $0.filename == filename }
    }
    
    func updateFilename(oldFilename: String, newFilename: String) {
        if let index = personPhotoHashes.firstIndex(where: { $0.filename == oldFilename }) {
            let existingEntry = personPhotoHashes[index]
            personPhotoHashes[index] = (filename: newFilename, featurePrint: existingEntry.featurePrint, completeness: existingEntry.completeness)
        }
    }
    
    func clear() {
        personPhotoHashes.removeAll()
    }
}

// MARK: - Vision Framework OCR Client
class VisionOCRClient {
    private let sessionManager = SessionManager()
    private var currentSession: SessionInfo?
    private let duplicateCache = DuplicateDetectionCache()
    
    func start() {
        print("Starting Vision OCR client...")
        currentSession = sessionManager.createNewSession()
        print("Created new session: \(currentSession?.sessionId ?? "unknown")")
    }
    
    func captureAndProcessWindow(windowName: String) -> (ocrResults: [OCRResult], extractedPhotos: [ExtractedPhoto])? {
        guard let windowImage = captureWindow(windowName: windowName) else {
            print("Failed to capture window: \(windowName)")
            return nil
        }
        
        let ocrResults = performOCR(on: windowImage)
        let extractedPhotos = extractPhotosFromImage(windowImage, ocrResults: ocrResults)
        
        return (ocrResults: ocrResults, extractedPhotos: extractedPhotos)
    }
    
    func captureWindow(windowName: String) -> NSImage? {
        // For compatibility with macOS versions where ScreenCaptureKit might not be available,
        // we'll use a fallback approach with screenshot of the entire screen and crop to window bounds
        guard let windowRect = getWindowPosition(windowName: windowName) else {
            print("Could not find window position for: \(windowName)")
            return nil
        }
        
        // Take screenshot of the specific window area
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        let tempImagePath = "/tmp/hinge_window_capture.png"
        task.arguments = ["-x", "-R", "\(Int(windowRect.origin.x)),\(Int(windowRect.origin.y)),\(Int(windowRect.width)),\(Int(windowRect.height))", tempImagePath]
        
        task.launch()
        task.waitUntilExit()
        
        if task.terminationStatus == 0,
           let image = NSImage(contentsOfFile: tempImagePath) {
            // Clean up temp file
            try? FileManager.default.removeItem(atPath: tempImagePath)
            return image
        }
        
        return nil
    }
    
    func performOCR(on image: NSImage) -> [OCRResult] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            
            var ocrResults: [OCRResult] = []
            
            if let observations = request.results {
                for observation in observations {
                    if let topCandidate = observation.topCandidates(1).first {
                        let boundingBox = observation.boundingBox
                        let imageHeight = CGFloat(cgImage.height)
                        let imageWidth = CGFloat(cgImage.width)
                        
                        // Convert Vision coordinates (bottom-left origin) to screen coordinates (top-left origin)
                        let convertedBoundingBox = CGRect(
                            x: boundingBox.origin.x * imageWidth,
                            y: (1 - boundingBox.origin.y - boundingBox.height) * imageHeight,
                            width: boundingBox.width * imageWidth,
                            height: boundingBox.height * imageHeight
                        )
                        
                        let result = OCRResult(
                            text: topCandidate.string,
                            boundingBox: convertedBoundingBox,
                            confidence: topCandidate.confidence
                        )
                        
                        ocrResults.append(result)
                    }
                }
            }
            
            return ocrResults
            
        } catch {
            print("OCR Error: \(error.localizedDescription)")
            return []
        }
    }
    
    private func hasUITextOverlay(_ imageRect: CGRect, ocrResults: [OCRResult]) -> Bool {
        // Enhanced text filtering that specifically checks for UI overlays
        return ocrResults.contains { ocrResult in
            let textRect = ocrResult.boundingBox
            
            // Check if text overlaps with the image region
            guard imageRect.intersects(textRect) else { return false }
            
            // Calculate overlap
            let intersection = imageRect.intersection(textRect)
            let overlapArea = intersection.width * intersection.height
            let regionArea = imageRect.width * imageRect.height
            let overlapPercentage = overlapArea / regionArea
            
            // Check for significant overlap (existing logic)
            if overlapPercentage > 0.3 {
                return true
            }
            
            // NEW: Check for UI text near borders (even with small overlap)
            let relativeTextRect = CGRect(
                x: (textRect.minX - imageRect.minX) / imageRect.width,
                y: (textRect.minY - imageRect.minY) / imageRect.height,
                width: textRect.width / imageRect.width,
                height: textRect.height / imageRect.height
            )
            
            // Check if text is near top/bottom edges with any overlap
            let nearTopEdge = relativeTextRect.minY < 0.2  // Top 20% of image
            let nearBottomEdge = relativeTextRect.maxY > 0.8  // Bottom 20% of image
            let hasAnyOverlap = overlapPercentage > 0.05  // Even 5% overlap is significant for UI text
            
            // Flag as UI overlay if text is near borders with any meaningful overlap
            if hasAnyOverlap && (nearTopEdge || nearBottomEdge) {
                aestheticSafePrint("🚫 Detected UI overlay: '\(ocrResult.text.prefix(20))...' at edge (overlap: \(String(format: "%.1f%%", overlapPercentage * 100)))")
                return true
            }
            
            return false
        }
    }
    
    private func createPersonCentricCrop(from imageRect: CGRect, personBox: CGRect, within imageSize: NSSize) -> CGRect {
        // Create a crop focused on the person with clean padding
        let personCenterX = personBox.midX
        let personCenterY = personBox.midY
        
        // Determine optimal crop size (try to maintain good aspect ratio)
        let personWidth = personBox.width
        let personHeight = personBox.height
        
        // Add 40% padding around person (20% on each side)
        let paddingMultiplier: CGFloat = 1.4
        let cropWidth = min(personWidth * paddingMultiplier, imageSize.width)
        let cropHeight = min(personHeight * paddingMultiplier, imageSize.height)
        
        // Center the crop around the person
        let cropX = max(0, min(personCenterX - cropWidth / 2, imageSize.width - cropWidth))
        let cropY = max(0, min(personCenterY - cropHeight / 2, imageSize.height - cropHeight))
        
        return CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
    }
    
    private func extractPhotosFromImage(_ image: NSImage, ocrResults: [OCRResult]) -> [ExtractedPhoto] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        
        // Create saliency request to find visually interesting regions (likely photos)
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            
            guard let observation = request.results?.first else {
                return []
            }
            
            var extractedPhotos: [ExtractedPhoto] = []
            let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
            
            // Get salient regions that don't overlap significantly with text
            let salientObjects = observation.salientObjects ?? []
            
            for (index, salientObject) in salientObjects.enumerated() {
                let boundingBox = salientObject.boundingBox
                
                // Convert to image coordinates
                let imageRect = CGRect(
                    x: boundingBox.origin.x * imageSize.width,
                    y: (1 - boundingBox.origin.y - boundingBox.height) * imageSize.height,
                    width: boundingBox.width * imageSize.width,
                    height: boundingBox.height * imageSize.height
                )
                
                // Enhanced text filtering - check for UI overlays
                let hasUIOverlay = hasUITextOverlay(imageRect, ocrResults: ocrResults)
                
                // Only extract regions that are likely clean photos
                if !hasUIOverlay && imageRect.width > 50 && imageRect.height > 50 {
                    // First extraction to check for person
                    if let initialCroppedCGImage = cgImage.cropping(to: imageRect) {
                        let initialImage = NSImage(cgImage: initialCroppedCGImage, size: NSSize(width: imageRect.width, height: imageRect.height))
                        
                        // Perform person detection on initial extraction
                        let personDetection = detectPersonsInImage(initialImage)
                        
                        var finalImage = initialImage
                        var finalRect = imageRect
                        
                        // If person detected, create person-centric crop to avoid remaining UI elements
                        if let detection = personDetection, detection.hasPerson, !detection.personBoundingBoxes.isEmpty {
                            let largestPersonBox = detection.personBoundingBoxes.max { box1, box2 in
                                (box1.width * box1.height) < (box2.width * box2.height)
                            }!
                            
                            // Convert person box from cropped image coordinates to original image coordinates
                            let personInOriginalCoords = CGRect(
                                x: imageRect.origin.x + largestPersonBox.origin.x,
                                y: imageRect.origin.y + largestPersonBox.origin.y,
                                width: largestPersonBox.width,
                                height: largestPersonBox.height
                            )
                            
                            // Create person-centric crop
                            let personCentricRect = createPersonCentricCrop(
                                from: imageRect,
                                personBox: personInOriginalCoords,
                                within: imageSize
                            )
                            
                            // Re-check for UI overlays in the person-centric crop
                            if !hasUITextOverlay(personCentricRect, ocrResults: ocrResults) {
                                if let personCentricCGImage = cgImage.cropping(to: personCentricRect) {
                                    finalImage = NSImage(cgImage: personCentricCGImage, size: NSSize(width: personCentricRect.width, height: personCentricRect.height))
                                    finalRect = personCentricRect
                                    aestheticSafePrint("✨ Applied person-centric crop to avoid UI elements")
                                }
                            }
                        }
                        
                        let filename = "extracted_photo_\(index + 1).jpg"
                        
                        var extractedPhoto = ExtractedPhoto(
                            image: finalImage,
                            boundingBox: finalRect,
                            filename: filename,
                            scrollPosition: 0, // Will be set by caller
                            personDetection: nil,
                            isSinglePerson: false,
                            primaryPersonBoundingBox: nil
                        )
                        
                        // Re-perform person detection on final image
                        extractedPhoto.personDetection = detectPersonsInImage(finalImage)
                        
                        // Analyze single vs multi-person and identify primary person
                        if let personDetection = extractedPhoto.personDetection, personDetection.hasPerson {
                            extractedPhoto.isSinglePerson = (personDetection.personCount == 1)
                            
                            // Find the largest/most prominent person (primary person)
                            if !personDetection.personBoundingBoxes.isEmpty {
                                let largestPersonBox = personDetection.personBoundingBoxes.max { box1, box2 in
                                    (box1.width * box1.height) < (box2.width * box2.height)
                                }
                                extractedPhoto.primaryPersonBoundingBox = largestPersonBox
                            }
                        }
                        
                        extractedPhotos.append(extractedPhoto)
                    }
                }
            }
            
            return extractedPhotos
            
        } catch {
            print("Saliency detection error: \(error.localizedDescription)")
            return []
        }
    }
    
    func searchForText(query: String, in ocrResults: [OCRResult]) -> [OCRResult] {
        return ocrResults.filter { result in
            result.text.lowercased().contains(query.lowercased())
        }
    }
    
    func savePhotosToSession(_ photos: [ExtractedPhoto], scrollIndex: Int) -> [PhotoMetadata] {
        guard let session = currentSession else { return [] }
        
        var photoMetadata: [PhotoMetadata] = []
        
        for (index, photo) in photos.enumerated() {
            // Determine subfolder based on person detection
            let subfolder: String
            if let personDetection = photo.personDetection, personDetection.hasPerson {
                subfolder = photo.isSinglePerson ? "person" : "multi_person"
            } else {
                subfolder = "other"
            }
            
            let baseFilename = "scroll_\(scrollIndex)_photo_\(index + 1).jpg"
            var actualFilename = baseFilename
            var duplicateStatus: DuplicateStatus = .unique
            var duplicateOfFilename: String? = nil
            let completenessScore = analyzeImageCompleteness(photo)
            
            // Only apply duplicate detection to person photos when enabled
            if isDuplicateDetectionEnabled && subfolder == "person" {
                if let featurePrint = generateFeaturePrint(for: photo.image) {
                    let duplicates = duplicateCache.findDuplicates(for: featurePrint, threshold: duplicateThreshold)
                    
                    if let bestDuplicate = duplicates.first {
                        let distance = bestDuplicate.distance
                        let existingCompleteness = bestDuplicate.completenessScore
                        
                        aestheticSafePrint("🔄 Duplicate detected: \(baseFilename) vs \(bestDuplicate.filename)")
                       aestheticSafePrint("   Distance: \(String(format: "%.3f", distance))")
                       aestheticSafePrint("   New completeness: \(String(format: "%.3f", completenessScore)), Existing: \(String(format: "%.3f", existingCompleteness))")
                        
                        if completenessScore > existingCompleteness {
                            // New image is more complete - replace the old one
                            if isMarkMode {
                                // Mark mode: save both with different names
                                actualFilename = "\(baseFilename.replacingOccurrences(of: ".jpg", with: ""))_PREFERRED.jpg"
                                duplicateStatus = .preferred
                                duplicateOfFilename = bestDuplicate.filename
                                
                                // Also rename the existing file to mark as duplicate (only if not already renamed)
                                let existingPath = sessionManager.getPhotosDirectory(for: session.sessionId)
                                    .appendingPathComponent("person")
                                    .appendingPathComponent(bestDuplicate.filename)
                                let duplicatePath = sessionManager.getPhotosDirectory(for: session.sessionId)
                                    .appendingPathComponent("person")
                                    .appendingPathComponent(bestDuplicate.filename.replacingOccurrences(of: ".jpg", with: "_DUPLICATE.jpg"))
                                
                                // Only rename if the original file still exists (hasn't been renamed already)
                                if FileManager.default.fileExists(atPath: existingPath.path) {
                                    do {
                                        try FileManager.default.moveItem(at: existingPath, to: duplicatePath)
                                        // Update cache with new filename
                                        let duplicateFilename = bestDuplicate.filename.replacingOccurrences(of: ".jpg", with: "_DUPLICATE.jpg")
                                        duplicateCache.updateFilename(oldFilename: bestDuplicate.filename, newFilename: duplicateFilename)
                                       aestheticSafePrint("   📝 Marked existing as duplicate: \(duplicatePath.lastPathComponent)")
                                    } catch {
                                        print("   ⚠️ Failed to rename existing file: \(error)")
                                    }
                                } else {
                                   aestheticSafePrint("   ℹ️ Original file already processed (likely renamed in previous duplicate detection)")
                                }
                            } else {
                                // Replace mode: delete the less complete version
                                let existingPath = sessionManager.getPhotosDirectory(for: session.sessionId)
                                    .appendingPathComponent("person")
                                    .appendingPathComponent(bestDuplicate.filename)
                                
                                do {
                                    try FileManager.default.removeItem(at: existingPath)
                                    duplicateCache.removePhoto(filename: bestDuplicate.filename)
                                    aestheticSafePrint("   🗑️ Removed less complete version: \(bestDuplicate.filename)")
                                } catch {
                                   aestheticSafePrint("   ⚠️ Failed to remove existing file: \(error)")
                                }
                            }
                        } else {
                            // Existing image is more complete - skip saving new one
                            if isMarkMode {
                                actualFilename = "\(baseFilename.replacingOccurrences(of: ".jpg", with: ""))_DUPLICATE.jpg"
                                duplicateStatus = .duplicate
                                duplicateOfFilename = bestDuplicate.filename
                            } else {
                                // Skip saving this photo entirely
                               aestheticSafePrint("   ⏭️ Skipping less complete version: \(baseFilename)")
                                continue
                            }
                        }
                    } else {
                        // No duplicates found - add to cache
                        duplicateCache.addPhoto(baseFilename, featurePrint: featurePrint, completeness: completenessScore)
                    }
                }
            }
            
            let subfolderPath = sessionManager.getPhotosDirectory(for: session.sessionId).appendingPathComponent(subfolder)
            let filePath = subfolderPath.appendingPathComponent(actualFilename)
            
            // Save original photo
            if let tiffData = photo.image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                
                do {
                    try jpegData.write(to: filePath)
                    let statusEmoji = duplicateStatus == .preferred ? "✨" : (duplicateStatus == .duplicate ? "📋" : "💾")
                    aestheticSafePrint("\(statusEmoji) Saved photo: \(subfolder)/\(actualFilename)")
                    
                    // For multi-person photos, also save a cropped version focusing on the primary person
                    if !photo.isSinglePerson && photo.personDetection?.hasPerson == true,
                       let primaryPersonBox = photo.primaryPersonBoundingBox,
                       let croppedImage = cropImageToHighlightPerson(photo.image, personBoundingBox: primaryPersonBox) {
                        
                        let croppedFilename = actualFilename.replacingOccurrences(of: ".jpg", with: "_cropped.jpg")
                        let croppedFilePath = subfolderPath.appendingPathComponent(croppedFilename)
                        
                        if let croppedTiffData = croppedImage.tiffRepresentation,
                           let croppedBitmap = NSBitmapImageRep(data: croppedTiffData),
                           let croppedJpegData = croppedBitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                            
                            try croppedJpegData.write(to: croppedFilePath)
                            aestheticSafePrint("✂️ Saved cropped photo: \(subfolder)/\(croppedFilename)")
                        }
                    }
                    
                    let metadata = PhotoMetadata(
                        filename: actualFilename,
                        boundingBox: photo.boundingBox,
                        scrollIndex: scrollIndex,
                        extractedAt: ISO8601DateFormatter().string(from: Date()),
                        personDetection: photo.personDetection,
                        isSinglePerson: photo.isSinglePerson,
                        primaryPersonBoundingBox: photo.primaryPersonBoundingBox,
                        subfolder: subfolder,
                        duplicateStatus: duplicateStatus,
                        completenessScore: completenessScore,
                        duplicateOfFilename: duplicateOfFilename
                    )
                    
                    photoMetadata.append(metadata)
                    
                } catch {
                    print("Error saving photo \(actualFilename): \(error.localizedDescription)")
                }
            }
        }
        
        return photoMetadata
    }
    
    func checkIPhoneInUseAndHandle(ocrResults: [OCRResult]) {
        let iphoneInUseResults = searchForText(query: "iPhone in Use", in: ocrResults)
        if !iphoneInUseResults.isEmpty {
            print("'iPhone in Use' message found. Looking for 'Try Again' button...")
            
            let tryAgainResults = searchForText(query: "Try Again", in: ocrResults)
            if let tryAgainResult = tryAgainResults.first {
                print("'Try Again' button found. Clicking it...")
                // Convert OCR bounding box to click coordinates
                let centerX = tryAgainResult.boundingBox.midX
                let centerY = tryAgainResult.boundingBox.midY
                performClick(at: (x: Double(centerX), y: Double(centerY), width: 10, height: 10), windowName: "iPhone Mirroring")
                Thread.sleep(forTimeInterval: 5)
            } else {
                print("'Try Again' button not found")
            }
        }
    }
    
    func getWindowPosition(windowName: String) -> CGRect? {
        guard let windowListInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as NSArray? as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowListInfo {
            if let name = windowInfo[kCGWindowName as String] as? String, name == windowName,
            let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
            let x = boundsDict["X"] as? CGFloat,
            let y = boundsDict["Y"] as? CGFloat,
            let width = boundsDict["Width"] as? CGFloat,
            let height = boundsDict["Height"] as? CGFloat {
                return CGRect(x: x, y: y, width: width, height: height)
            }
        }
        return nil
    }
    
    func isWindowInForeground(windowName: String) -> Bool {
        guard let windowListInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray? as? [[String: Any]] else {
            return false
        }

        if let frontmostWindow = windowListInfo.first,
           let name = frontmostWindow[kCGWindowName as String] as? String {
            return name == windowName
        }

        return false
    }

    func performClick(at coordinates: (x: Double, y: Double, width: Double, height: Double), windowName: String, doubleClick: Bool = false, verticalOffset: CGFloat = 0) {
        guard let windowPosition = getWindowPosition(windowName: windowName) else {
            print("Could not find window position for window: \(windowName)")
            return
        }

        let clickX = windowPosition.origin.x + (CGFloat(coordinates.x) * windowPosition.width)
        let clickY = windowPosition.origin.y + ((1 - CGFloat(coordinates.y)) * windowPosition.height) + verticalOffset

        let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left)
        let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left)
        let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left)

        mouseMoveEvent?.post(tap: .cghidEventTap)
        mouseDownEvent?.post(tap: .cghidEventTap)
        mouseUpEvent?.post(tap: .cghidEventTap)

        if doubleClick || !isWindowInForeground(windowName: windowName) {
            Thread.sleep(forTimeInterval: 0.1)
            mouseDownEvent?.post(tap: .cghidEventTap)
            mouseUpEvent?.post(tap: .cghidEventTap)
        }

        aestheticSafePrint("Performed \(doubleClick ? "double " : "")click at coordinates: x: \(clickX), y: \(clickY) for window: \(windowName)")
    }
    
    private func cropImageToHighlightPerson(_ image: NSImage, personBoundingBox: CGRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
        
        // Add padding around the person (20% on each side)
        let padding: CGFloat = 0.2
        let paddedWidth = personBoundingBox.width * (1 + 2 * padding)
        let paddedHeight = personBoundingBox.height * (1 + 2 * padding)
        
        let cropX = max(0, personBoundingBox.origin.x - (personBoundingBox.width * padding))
        let cropY = max(0, personBoundingBox.origin.y - (personBoundingBox.height * padding))
        let cropWidth = min(paddedWidth, imageSize.width - cropX)
        let cropHeight = min(paddedHeight, imageSize.height - cropY)
        
        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        
        if let croppedCGImage = cgImage.cropping(to: cropRect) {
            return NSImage(cgImage: croppedCGImage, size: NSSize(width: cropRect.width, height: cropRect.height))
        }
        
        return nil
    }
    
    private func analyzeImageCompleteness(_ photo: ExtractedPhoto) -> Float {
        // Primary factor: Person detection bounding box area coverage
        guard let personDetection = photo.personDetection,
              personDetection.hasPerson,
              let primaryPersonBox = photo.primaryPersonBoundingBox else {
            return 0.0
        }
        
        // Calculate person coverage relative to the extracted photo area
        let photoArea = photo.boundingBox.width * photo.boundingBox.height
        let personArea = primaryPersonBox.width * primaryPersonBox.height
        
        // Ensure we don't divide by zero
        guard photoArea > 0 else { return 0.0 }
        
        // Return ratio (0.0 to 1.0, where 1.0 means person fills entire image)
        // Clamp to maximum of 1.0 in case of calculation errors
        return min(1.0, Float(personArea / photoArea))
    }
    
    private func generateFeaturePrint(for image: NSImage) -> VNFeaturePrintObservation? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            print("Error generating feature print: \(error)")
            return nil
        }
    }
    
    private func detectPersonsInImage(_ image: NSImage) -> PersonDetectionResult? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return PersonDetectionResult(hasPerson: false, personCount: 0, confidence: 0.0, personBoundingBoxes: [])
        }
        
        // Create person detection request
        let request = VNDetectHumanRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            
            guard let observations = request.results, !observations.isEmpty else {
                return PersonDetectionResult(hasPerson: false, personCount: 0, confidence: 0.0, personBoundingBoxes: [])
            }
            
            let personCount = observations.count
            let avgConfidence = observations.reduce(0.0) { $0 + $1.confidence } / Float(personCount)
            
            // Convert bounding boxes to image coordinates
            let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
            let personBoundingBoxes = observations.map { observation in
                let boundingBox = observation.boundingBox
                return CGRect(
                    x: boundingBox.origin.x * imageSize.width,
                    y: (1 - boundingBox.origin.y - boundingBox.height) * imageSize.height,
                    width: boundingBox.width * imageSize.width,
                    height: boundingBox.height * imageSize.height
                )
            }
            
            return PersonDetectionResult(
                hasPerson: true,
                personCount: personCount,
                confidence: avgConfidence,
                personBoundingBoxes: personBoundingBoxes
            )
            
        } catch {
            print("Person detection error: \(error.localizedDescription)")
            return PersonDetectionResult(hasPerson: false, personCount: 0, confidence: 0.0, personBoundingBoxes: [])
        }
    }
    
    func compareScreenshots(_ image1: NSImage, _ image2: NSImage, threshold: Float = 0.90) -> Bool {
        guard let cgImage1 = image1.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cgImage2 = image2.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        
        // Quick size check
        if cgImage1.width != cgImage2.width || cgImage1.height != cgImage2.height {
            return false
        }
        
        // Crop out top 60 pixels to exclude time/status bar from comparison
        let cropHeight = 60
        let croppedImage1 = cgImage1.cropping(to: CGRect(x: 0, y: cropHeight, width: cgImage1.width, height: cgImage1.height - cropHeight))
        let croppedImage2 = cgImage2.cropping(to: CGRect(x: 0, y: cropHeight, width: cgImage2.width, height: cgImage2.height - cropHeight))
        
        guard let finalImage1 = croppedImage1, let finalImage2 = croppedImage2 else {
            return false
        }
        
        // Use Vision Framework to compare image similarity
        let request1 = VNGenerateImageFeaturePrintRequest()
        let request2 = VNGenerateImageFeaturePrintRequest()
        
        let handler1 = VNImageRequestHandler(cgImage: finalImage1, options: [:])
        let handler2 = VNImageRequestHandler(cgImage: finalImage2, options: [:])
        
        do {
            try handler1.perform([request1])
            try handler2.perform([request2])
            
            guard let featurePrint1 = request1.results?.first,
                  let featurePrint2 = request2.results?.first else {
                return false
            }
            
            // Compare feature prints
            var distance: Float = 0
            try featurePrint1.computeDistance(&distance, to: featurePrint2)
            
            // Convert distance to similarity (lower distance = higher similarity)
            let similarity = 1.0 - distance
            
            aestheticSafePrint("Screenshot similarity: \(String(format: "%.3f", similarity)) (threshold: \(threshold))")
            return similarity >= threshold
            
        } catch {
            print("Screenshot comparison error: \(error.localizedDescription)")
            // Fallback: simple pixel comparison for a small sample
            return compareScreenshotsSimple(finalImage1, finalImage2, threshold: threshold)
        }
    }
    
    private func compareScreenshotsSimple(_ cgImage1: CGImage, _ cgImage2: CGImage, threshold: Float) -> Bool {
        // Simple pixel-based comparison as fallback
        let width = min(cgImage1.width, cgImage2.width)
        let height = min(cgImage1.height, cgImage2.height)
        
        // Sample every 10th pixel for performance
        let _ = max(1, width * height / 10000) // Sample size calculation for reference
        var matchingPixels = 0
        var totalSamples = 0
        
        // Create data providers
        guard let dataProvider1 = cgImage1.dataProvider,
              let dataProvider2 = cgImage2.dataProvider,
              let data1 = dataProvider1.data,
              let data2 = dataProvider2.data else {
            return false
        }
        
        let ptr1 = CFDataGetBytePtr(data1)
        let ptr2 = CFDataGetBytePtr(data2)
        
        for y in stride(from: 0, to: height, by: 10) {
            for x in stride(from: 0, to: width, by: 10) {
                let offset = (y * width + x) * 4 // Assuming RGBA
                if offset + 3 < CFDataGetLength(data1) && offset + 3 < CFDataGetLength(data2) {
                    let r1 = ptr1![offset], g1 = ptr1![offset + 1], b1 = ptr1![offset + 2]
                    let r2 = ptr2![offset], g2 = ptr2![offset + 1], b2 = ptr2![offset + 2]
                    
                    // Allow small color differences (within 10 units)
                    let rDiff = abs(Int(r1) - Int(r2))
                    let gDiff = abs(Int(g1) - Int(g2))
                    let bDiff = abs(Int(b1) - Int(b2))
                    
                    if rDiff <= 10 && gDiff <= 10 && bDiff <= 10 {
                        matchingPixels += 1
                    }
                    totalSamples += 1
                }
            }
        }
        
        let similarity = totalSamples > 0 ? Float(matchingPixels) / Float(totalSamples) : 0.0
       aestheticSafePrint("Simple screenshot similarity: \(String(format: "%.3f", similarity))")
        return similarity >= threshold
    }
    
    func getAllText(from ocrResults: [OCRResult]) -> String {
        return ocrResults.map { $0.text }.joined(separator: "\n")
    }
    
    func getCurrentSessionId() -> String? {
        return currentSession?.sessionId
    }
    
    func getCurrentSession() -> SessionInfo? {
        return currentSession
    }
    
    func getSessionManager() -> SessionManager {
        return sessionManager
    }
    
    func callVisionProcessor(photosDir: String, criterion: String, provider: String = "openai", isAesthetic: Bool = false, ocrText: String? = nil) -> [String: Any]? {
        guard let session = currentSession else {
           aestheticSafePrint("❌ No active session for vision processing")
            return nil
        }

        // Choose script and output file based on provider
        let (pythonScript, outputFileName, apiName) = provider == "grok"
            ? ("grok_vision_processor.py", "grok_analysis.json", "Grok Vision")
            : ("openai_vision_processor.py", "openai_analysis.json", "OpenAI Vision")

        // Create output path in session directory
        let outputPath = sessionManager.getSessionDirectory(for: session.sessionId)
            .appendingPathComponent(outputFileName)

        aestheticSafePrint("🤖 Calling \(apiName) API for profile analysis...")
        aestheticSafePrint("📁 Photos directory: \(photosDir)")
        aestheticSafePrint("🎯 Criterion: \(criterion)")
        aestheticSafePrint("💾 Output path: \(outputPath.path)")

        // Prepare Python command
        var command = [
            "python3", pythonScript,
            "--photos-dir", photosDir,
            "--criterion", criterion,
            "--output", outputPath.path
        ]

        // Add aesthetic flag if needed
        if isAesthetic {
            command.append("--aesthetic")
        }

        // Add OCR text if provided
        if let text = ocrText, !text.isEmpty {
            command.append("--text")
            command.append(text)
        }
        
        // Execute Python script
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = command

        // Pass environment variables to the subprocess
        var environment = ProcessInfo.processInfo.environment

        // Ensure API keys are available to the Python script
        if let openaiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] {
            environment["OPENAI_API_KEY"] = openaiKey
        }
        if let xaiKey = ProcessInfo.processInfo.environment["XAI_API_KEY"] {
            environment["XAI_API_KEY"] = xaiKey
        }

        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            if process.terminationStatus == 0 {
                aestheticSafePrint("✅ \(apiName) analysis completed successfully")
                if !isAesthetic {
                   aestheticSafePrint("📄 Output: \(output)")
                }

                // Read and parse the results
                do {
                    let resultData = try Data(contentsOf: outputPath)
                    let result = try JSONSerialization.jsonObject(with: resultData, options: []) as? [String: Any]

                    showAestheticAction("think")
                    if !isAesthetic {
                        aestheticSafePrint("🧠 Analysis Result:")
                        if let decision = result?["decision"] as? String {
                            aestheticSafePrint("   Decision: \(decision)")
                        }
                        if let reasoning = result?["reasoning"] as? String {
                            if showReasoning {
                                let cleanReasoning = extractReasoningFromResponse(reasoning)
                                aestheticSafePrint("   Reasoning: \(cleanReasoning)")
                            }
                        }
                        if let photoCount = result?["photo_count"] as? Int {
                            aestheticSafePrint("   Photos analyzed: \(photoCount)")
                        }
                    }

                    return result

                } catch {
                    print("❌ Failed to read \(apiName) results: \(error)")
                    return nil
                }
                
            } else {
                print("❌ \(apiName) processing failed with exit code \(process.terminationStatus)")
                print("📄 Error output: \(output)")
                return nil
            }
            
        } catch {
            print("❌ Failed to launch \(apiName) processor: \(error)")
            return nil
        }
    }
    
    // Legacy compatibility method
    func callOpenAIVisionProcessor(photosDir: String, criterion: String) -> [String: Any]? {
        return callVisionProcessor(photosDir: photosDir, criterion: criterion, provider: "openai")
    }
    
    // New Grok Vision method
    func callGrokVisionProcessor(photosDir: String, criterion: String) -> [String: Any]? {
        return callVisionProcessor(photosDir: photosDir, criterion: criterion, provider: "grok")
    }
    
    func stop() {
        if let session = currentSession {
            sessionManager.finalizeSession(session)
        }
    }
}

// MARK: - iPhone Mirroring Functions
func isIPhoneMirroringRunning() -> Bool {
    let task = Process()
    task.launchPath = "/usr/bin/pgrep"
    task.arguments = ["-if", "iPhone Mirroring"]
    
    let pipe = Pipe()
    task.standardOutput = pipe
    task.launch()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)
    
    return !(output?.isEmpty ?? true)
}

func startIPhoneMirroring() {
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = ["-a", "iPhone Mirroring"]
    task.launch()
    task.waitUntilExit()
    
    print("Waiting 10 seconds for iPhone Mirroring to fully load...")
    Thread.sleep(forTimeInterval: 10)
}

func bringIPhoneMirroringToForeground() {
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", "tell application \"iPhone Mirroring\" to activate"]
    task.launch()
    task.waitUntilExit()
    
    aestheticSafePrint("Brought iPhone Mirroring to foreground")
    Thread.sleep(forTimeInterval: 2)
    
    // Also click in the center of the iPhone Mirroring window to ensure focus
    clickInIPhoneMirroringCenter()
}

func clickInIPhoneMirroringCenter() {
    // Get all windows and find iPhone Mirroring
    guard let windowListInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as NSArray? as? [[String: Any]] else {
        return
    }

    for windowInfo in windowListInfo {
        if let name = windowInfo[kCGWindowName as String] as? String, 
           name.contains("iPhone Mirroring"),
           let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
           let x = boundsDict["X"] as? CGFloat,
           let y = boundsDict["Y"] as? CGFloat,
           let width = boundsDict["Width"] as? CGFloat,
           let height = boundsDict["Height"] as? CGFloat {
            
            let centerX = x + width / 2
            let centerY = y + height / 2
            
            let clickEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: centerX, y: centerY), mouseButton: .left)
            let releaseEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: centerX, y: centerY), mouseButton: .left)
            
            clickEvent?.post(tap: .cghidEventTap)
            releaseEvent?.post(tap: .cghidEventTap)
            
            aestheticSafePrint("Clicked in iPhone Mirroring center for focus")
            Thread.sleep(forTimeInterval: 1)
            break
        }
    }
}

// MARK: - Key Press Functions
func simulateKeyPress(key: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
}

func simulateMouseWheelScroll(scrollAmount: Int32) {
    let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: scrollAmount, wheel2: 0, wheel3: 0)
    scrollEvent?.post(tap: .cghidEventTap)
}

// MARK: - Swipe Decision Logic
struct ProfileFilterResult {
    let shouldFilter: Bool
    let reason: String
    let soloPhotoCount: Int
    let totalPhotoCount: Int
}

func evaluateProfileFilter(from photoMetadata: [PhotoMetadata], minSoloPhotos: Int = 2) -> ProfileFilterResult {
    let totalPhotos = photoMetadata.count
    let soloPhotos = photoMetadata.filter { $0.isSinglePerson }.count
    
    if soloPhotos < minSoloPhotos {
        return ProfileFilterResult(
            shouldFilter: true,
            reason: "Insufficient solo photos (\(soloPhotos)/\(minSoloPhotos) minimum)",
            soloPhotoCount: soloPhotos,
            totalPhotoCount: totalPhotos
        )
    }
    
    return ProfileFilterResult(
        shouldFilter: false,
        reason: "Profile meets solo photo criteria (\(soloPhotos)/\(minSoloPhotos) minimum)",
        soloPhotoCount: soloPhotos,
        totalPhotoCount: totalPhotos
    )
}

func makeMajorityDecision(from photoMetadata: [PhotoMetadata], minSoloPhotos: Int = 2, enforceFilter: Bool = false) -> (shouldLike: Bool, filterResult: ProfileFilterResult) {
    let totalPhotos = photoMetadata.count
    let personPhotos = photoMetadata.filter { $0.personDetection?.hasPerson == true }.count
    let soloPhotos = photoMetadata.filter { $0.isSinglePerson }.count
    
    aestheticSafePrint("\u{1F4CA} Decision Analysis:")
    aestheticSafePrint("  Total photos: \(totalPhotos)")
    aestheticSafePrint("  Photos with people: \(personPhotos)")
    aestheticSafePrint("  Solo person photos: \(soloPhotos)")
    
    // Evaluate profile filter
    let filterResult = evaluateProfileFilter(from: photoMetadata, minSoloPhotos: minSoloPhotos)
    
    aestheticSafePrint("  Filter result: \(filterResult.reason)")
    
    if totalPhotos == 0 {
        aestheticSafePrint("  \u{26A0} No photos found - defaulting to PASS")
        return (shouldLike: false, filterResult: filterResult)
    }
    
    // If enforcing filter and profile should be filtered, auto-pass
    if enforceFilter && filterResult.shouldFilter {
        print("  \u{1F6AB} AUTO-PASS: Profile filtered due to insufficient solo photos")
        return (shouldLike: false, filterResult: filterResult)
    }
    
    let personPhotoRatio = Float(personPhotos) / Float(totalPhotos)
    aestheticSafePrint("  Person photo ratio: \(String(format: "%.1f%%", personPhotoRatio * 100))")
    
    // Enhanced decision logic: prioritize profiles with more solo photos
    let shouldLike: Bool
    
    if soloPhotos >= 2 {
        // Strong preference for profiles with 2+ solo photos
        shouldLike = personPhotoRatio > 0.4 // Lower threshold for good profiles
    } else if soloPhotos == 1 {
        // Moderate preference for profiles with 1 solo photo
        shouldLike = personPhotoRatio > 0.6 // Higher threshold
    } else {
        // Very selective for profiles with no solo photos
        shouldLike = personPhotoRatio > 0.8 // Very high threshold
    }
    
    if shouldLike {
        aestheticSafePrint("  \u{2705} LIKE decision: Good person photo profile (\(personPhotos) person photos, \(soloPhotos) solo)")
    } else {
        aestheticSafePrint("  \u{274C} PASS decision: Insufficient quality photos (\(personPhotos) person photos, \(soloPhotos) solo)")
    }
    
    return (shouldLike: shouldLike, filterResult: filterResult)
}

// MARK: - Action Verification Functions
func verifyActionCompleted(client: VisionOCRClient, windowName: String, beforeScreenshot: NSImage, actionDescription: String, maxRetries: Int = 3) -> Bool {
    Thread.sleep(forTimeInterval: 1) // Wait for UI to update
    
    guard let afterScreenshot = client.captureWindow(windowName: windowName) else {
        print("⚠️ Failed to capture screenshot after \(actionDescription)")
        return false
    }
    
    let isSame = client.compareScreenshots(beforeScreenshot, afterScreenshot, threshold: 0.85)
    
    if isSame {
        aestheticSafePrint("⚠️ Screenshot unchanged after \(actionDescription) - action may have failed")
        return false
    } else {
        aestheticSafePrint("✅ Screenshot changed after \(actionDescription) - action successful")
        return true
    }
}

func ensureIPhoneMirroringFocus() {
    aestheticSafePrint("🔄 Ensuring iPhone Mirroring has focus...")
    bringIPhoneMirroringToForeground()
    Thread.sleep(forTimeInterval: 1)
}

// MARK: - Swipe Functions with Verification
func performSwipeLeft(client: VisionOCRClient, windowName: String, config: Config? = nil, isAesthetic: Bool = false) {
    let maxRetries = 3
    
    for attempt in 1...maxRetries {
        aestheticSafePrint("\u{1F448} Performing SWIPE LEFT (Pass) - Attempt \(attempt)/\(maxRetries)")
        
        // Capture screenshot before action
        guard let beforeScreenshot = client.captureWindow(windowName: windowName) else {
            print("Failed to capture screenshot before swipe left")
            ensureIPhoneMirroringFocus()
            continue
        }
        
        guard let windowPosition = client.getWindowPosition(windowName: windowName) else {
            print("Could not find window position for window: \(windowName)")
            ensureIPhoneMirroringFocus()
            continue
        }
        
        // X button coordinates: bottom left corner (10% from left, 90% from top)
        let xButtonX = windowPosition.origin.x + (windowPosition.width * 0.10)
        let xButtonY = windowPosition.origin.y + (windowPosition.height * 0.90)
        
        aestheticSafePrint("Clicking X button at x: \(xButtonX), y: \(xButtonY)")
        
        let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: xButtonX, y: xButtonY), mouseButton: .left)
        let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: xButtonX, y: xButtonY), mouseButton: .left)
        let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: xButtonX, y: xButtonY), mouseButton: .left)
        
        mouseMoveEvent?.post(tap: .cghidEventTap)
        mouseDownEvent?.post(tap: .cghidEventTap)
        mouseUpEvent?.post(tap: .cghidEventTap)
        
        // Verify action completed
        if verifyActionCompleted(client: client, windowName: windowName, beforeScreenshot: beforeScreenshot, actionDescription: "swipe left") {
            showAestheticAction("swipe_left")
            aestheticSafePrint("\u{274C} Swiped LEFT - Profile passed")
            return
        } else {
            aestheticSafePrint("\u{26a0} Swipe LEFT failed, retrying...")
            ensureIPhoneMirroringFocus()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    aestheticSafePrint("\u{274c} Failed to complete swipe LEFT after \(maxRetries) attempts")
}

func performSendLikeClickWithVerification(client: VisionOCRClient, windowName: String) -> Bool {
    let maxRetries = 3
    
    for attempt in 1...maxRetries {
        aestheticSafePrint("\u{1F48C} Clicking Send Like button - Attempt \(attempt)/\(maxRetries)")
        
        // Capture screenshot before Send Like action
        guard let beforeSendLikeScreenshot = client.captureWindow(windowName: windowName) else {
            aestheticSafePrint("Failed to capture screenshot before Send Like click")
            ensureIPhoneMirroringFocus()
            continue
        }
        
        guard let windowPosition = client.getWindowPosition(windowName: windowName) else {
            aestheticSafePrint("Could not find window position for window: \(windowName)")
            ensureIPhoneMirroringFocus()
            continue
        }
        
        // Send Like button coordinates: same position as heart button (90% from left, 80% from top)
        let sendLikeButtonX = windowPosition.origin.x + (windowPosition.width * 0.90)
        let sendLikeButtonY = windowPosition.origin.y + (windowPosition.height * 0.80)
        
        aestheticSafePrint("Clicking Send Like button at x: \(sendLikeButtonX), y: \(sendLikeButtonY)")
        
        let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: sendLikeButtonX, y: sendLikeButtonY), mouseButton: .left)
        let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: sendLikeButtonX, y: sendLikeButtonY), mouseButton: .left)
        let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: sendLikeButtonX, y: sendLikeButtonY), mouseButton: .left)
        
        mouseMoveEvent?.post(tap: .cghidEventTap)
        mouseDownEvent?.post(tap: .cghidEventTap)
        mouseUpEvent?.post(tap: .cghidEventTap)
        
        // Verify Send Like action completed
        if verifyActionCompleted(client: client, windowName: windowName, beforeScreenshot: beforeSendLikeScreenshot, actionDescription: "Send Like click") {
            print("\u{2705} Send Like confirmed - returned to main feed")
            return true
        } else {
            print("\u{26a0} Send Like failed, retrying...")
            ensureIPhoneMirroringFocus()
            Thread.sleep(forTimeInterval: 1)
        }
    }
    
    print("\u{274c} Failed to complete Send Like after \(maxRetries) attempts")
    return false
}

// Legacy function for backward compatibility
func performSendLikeClick(client: VisionOCRClient, windowName: String) {
    _ = performSendLikeClickWithVerification(client: client, windowName: windowName)
}

func handleSendRoseScreen(client: VisionOCRClient, windowName: String) -> Bool {
    aestheticSafePrint("🔍 Checking for 'Send rose instead' screen...")

    // Capture current screen for OCR analysis
    guard let currentScreenshot = client.captureWindow(windowName: windowName) else {
        print("Failed to capture screenshot for rose detection")
        return false
    }

    // Perform OCR to detect "Send rose instead" text
    let ocrResults = client.performOCR(on: currentScreenshot)
    let allText = ocrResults.map { $0.text.lowercased() }.joined(separator: " ")

    if allText.contains("send rose instead") || allText.contains("rose instead") {
        aestheticSafePrint("🌹 Detected 'Send rose instead' screen")

        // Look for "Send like" button text in OCR results
        var sendLikeButtonLocation: CGRect?
        for result in ocrResults {
            let text = result.text.lowercased()
            if text.contains("send like") || text == "send like" {
                sendLikeButtonLocation = result.boundingBox
                break
            }
        }

        if let buttonBounds = sendLikeButtonLocation {
            // Click on the "Send like" button using OCR coordinates
            guard let windowPosition = client.getWindowPosition(windowName: windowName) else {
                print("Could not find window position")
                return false
            }

            // Convert OCR coordinates to screen coordinates
            let buttonCenterX = windowPosition.origin.x + buttonBounds.midX
            let buttonCenterY = windowPosition.origin.y + buttonBounds.midY

            aestheticSafePrint("💖 Clicking 'Send like' button at OCR location")
            print("Clicking Send like button at x: \(buttonCenterX), y: \(buttonCenterY)")

            let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: buttonCenterX, y: buttonCenterY), mouseButton: .left)
            let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: buttonCenterX, y: buttonCenterY), mouseButton: .left)
            let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: buttonCenterX, y: buttonCenterY), mouseButton: .left)

            mouseMoveEvent?.post(tap: .cghidEventTap)
            mouseDownEvent?.post(tap: .cghidEventTap)
            mouseUpEvent?.post(tap: .cghidEventTap)

            // Wait for action to complete and verify return to main feed
            Thread.sleep(forTimeInterval: 2)

            // Verify we returned to main feed by checking the screen changed
            if verifyActionCompleted(client: client, windowName: windowName, beforeScreenshot: currentScreenshot, actionDescription: "Send like from rose screen") {
                aestheticSafePrint("✅ Successfully clicked 'Send like' and returned to main feed")
                return true
            } else {
                print("⚠️ Send like click may not have worked properly")
                return false
            }
        } else {
            // Fallback: try clicking at default Send Like button location if OCR didn't find the button
            aestheticSafePrint("⚠️ Could not find 'Send like' button text, trying default location")
            return performSendLikeClickWithVerification(client: client, windowName: windowName)
        }
    } else {
        // No "Send rose instead" detected, proceed with normal Send Like flow
        aestheticSafePrint("📝 Normal send like screen detected")
        return performSendLikeClickWithVerification(client: client, windowName: windowName)
    }
}

func performSwipeRight(client: VisionOCRClient, windowName: String, config: Config? = nil, isAesthetic: Bool = false) {
    let maxRetries = 3
    
    for attempt in 1...maxRetries {
        aestheticSafePrint("\u{1F449} Performing SWIPE RIGHT (Like) - Attempt \(attempt)/\(maxRetries)")
        
        // Capture screenshot before heart action
        guard let beforeHeartScreenshot = client.captureWindow(windowName: windowName) else {
            print("Failed to capture screenshot before heart click")
            ensureIPhoneMirroringFocus()
            continue
        }
        
        guard let windowPosition = client.getWindowPosition(windowName: windowName) else {
            print("Could not find window position for window: \(windowName)")
            ensureIPhoneMirroringFocus()
            continue
        }
        
        // Heart button coordinates: bottom right (90% from left, 80% from top)
        let heartButtonX = windowPosition.origin.x + (windowPosition.width * 0.90)
        let heartButtonY = windowPosition.origin.y + (windowPosition.height * 0.80)
        
        aestheticSafePrint("Clicking heart button at x: \(heartButtonX), y: \(heartButtonY)")
        
        let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: heartButtonX, y: heartButtonY), mouseButton: .left)
        let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: heartButtonX, y: heartButtonY), mouseButton: .left)
        let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: heartButtonX, y: heartButtonY), mouseButton: .left)
        
        mouseMoveEvent?.post(tap: .cghidEventTap)
        mouseDownEvent?.post(tap: .cghidEventTap)
        mouseUpEvent?.post(tap: .cghidEventTap)
        
        // Verify heart click opened Send Like page
        if verifyActionCompleted(client: client, windowName: windowName, beforeScreenshot: beforeHeartScreenshot, actionDescription: "heart click") {
            print("\u{2764} Heart clicked - Send Like page opened")

            // Check for "Send rose instead" screen and handle accordingly
            if handleSendRoseScreen(client: client, windowName: windowName) {
                showAestheticAction("swipe_right")
                aestheticSafePrint("\u{2764} Swiped RIGHT - Profile liked and confirmed")
                return
            } else {
                aestheticSafePrint("\u{26a0} Send Like failed, retrying entire sequence...")
            }
        } else {
            aestheticSafePrint("\u{26a0} Heart click failed, retrying...")
            ensureIPhoneMirroringFocus()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    aestheticSafePrint("\u{274c} Failed to complete swipe RIGHT after \(maxRetries) attempts")
}

// MARK: - Testing Functions
func testSwipeActions(client: VisionOCRClient, windowName: String) {
    print("\u{1F9EA} Testing swipe functionality...")
    print("Choose which swipe to test:")
    print("1. Swipe LEFT (X button)")
    print("2. Swipe RIGHT (Heart button)")
    print("3. Test both")
    print("Enter your choice (1, 2, or 3): ", terminator: "")
    
    guard let input = readLine(), let choice = Int(input) else {
        print("Invalid input. Testing both actions.")
        testBothSwipes(client: client, windowName: windowName)
        return
    }
    
    switch choice {
    case 1:
        print("\n1. Testing SWIPE LEFT (X button):")
        performSwipeLeft(client: client, windowName: windowName)
    case 2:
        print("\n2. Testing SWIPE RIGHT (Heart button):")
        performSwipeRight(client: client, windowName: windowName)
    case 3:
        testBothSwipes(client: client, windowName: windowName)
    default:
        print("Invalid choice. Testing both actions.")
        testBothSwipes(client: client, windowName: windowName)
    }
    
    print("\n\u{2705} Swipe testing complete!")
}

func testBothSwipes(client: VisionOCRClient, windowName: String) {
    print("\n1. Testing SWIPE LEFT (X button):")
    performSwipeLeft(client: client, windowName: windowName)
    
    Thread.sleep(forTimeInterval: 3)
    
    print("\n2. Testing SWIPE RIGHT (Heart button):")
    performSwipeRight(client: client, windowName: windowName)
}

// MARK: - Scroll and Capture Functions
func cleanupDuplicatePhotos(from similarScrollCycles: [Int], photoMetadata: inout [PhotoMetadata], client: VisionOCRClient) {
    guard let sessionId = client.getCurrentSessionId() else {
        print("⚠️ No session ID available for cleanup")
        return
    }
    
    // Get session manager to access photo directories
    let sessionManager = SessionManager()
    let photosBaseDir = sessionManager.getPhotosDirectory(for: sessionId)
    
    var removedCount = 0
    var indicesToRemove: [Int] = []
    
    // Find all photos from similar scroll cycles
    for (index, photoMeta) in photoMetadata.enumerated() {
        if similarScrollCycles.contains(photoMeta.scrollIndex) {
            // Mark for removal from metadata
            indicesToRemove.append(index)
            
            // Delete actual photo files
            let subfolder = photoMeta.subfolder
            let subfolderPath = photosBaseDir.appendingPathComponent(subfolder)
            let photoPath = subfolderPath.appendingPathComponent(photoMeta.filename)
            
            do {
                // Delete original photo
                if FileManager.default.fileExists(atPath: photoPath.path) {
                    try FileManager.default.removeItem(at: photoPath)
                    removedCount += 1
                    aestheticSafePrint("  🗑️ Removed duplicate: \(subfolder)/\(photoMeta.filename)")
                }
                
                // Also delete cropped version if it exists (for multi_person photos)
                if subfolder == "multi_person" {
                    let croppedFilename = photoMeta.filename.replacingOccurrences(of: ".jpg", with: "_cropped.jpg")
                    let croppedPhotoPath = subfolderPath.appendingPathComponent(croppedFilename)
                    
                    if FileManager.default.fileExists(atPath: croppedPhotoPath.path) {
                        try FileManager.default.removeItem(at: croppedPhotoPath)
                        aestheticSafePrint("  🗑️ Removed duplicate cropped: \(subfolder)/\(croppedFilename)")
                    }
                }
                
            } catch {
                print("  ❌ Failed to remove \(subfolder)/\(photoMeta.filename): \(error.localizedDescription)")
            }
        }
    }
    
    // Remove metadata entries in reverse order to maintain indices
    for index in indicesToRemove.reversed() {
        photoMetadata.remove(at: index)
    }
    
    aestheticSafePrint("✅ Cleanup complete: Removed \(removedCount) duplicate photos from \(similarScrollCycles.count) similar scroll cycles")
}

func scrollToBottomAndCaptureData(scrollData: inout [String: String], client: VisionOCRClient, windowName: String, photoMetadata: inout [PhotoMetadata], scrollDelay: Double = 1.0, config: Config? = nil, isAesthetic: Bool = false, visionProvider: String = "openai") -> [String: Any]? {
    aestheticSafePrint("\u{1F4DC} Starting comprehensive profile scroll to bottom...")

    var scrollCount = 0
    let maxScrollAttempts = 15 // Safety limit
    var consecutiveSameScreenshots = 0
    var similarScrollCycles: [Int] = [] // Track which scroll cycles had similar screenshots

    while scrollCount < maxScrollAttempts {
        scrollCount += 1
        if !isAesthetic {
            print("\n--- Scroll \(scrollCount) ---")
        }
        
        // Capture screenshot BEFORE scrolling
        let beforeScrollScreenshot = client.captureWindow(windowName: windowName)
        
        // Perform scroll
        if let windowRect = client.getWindowPosition(windowName: windowName) {
            let centerX = windowRect.origin.x + windowRect.width / 2
            let centerY = windowRect.origin.y + windowRect.height / 2
            
            let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: centerX, y: centerY), mouseButton: .left)
            mouseMoveEvent?.post(tap: .cghidEventTap)
            
            // Slower, more deliberate scrolling
            for _ in 1...3 {
                simulateMouseWheelScroll(scrollAmount: -150)
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            showAestheticAction("scroll")
            aestheticSafePrint("Scrolled down...")
        } else {
            aestheticSafePrint("Could not find window position")
            break
        }
        
        Thread.sleep(forTimeInterval: max(0.1, scrollDelay)) // Wait for content to stabilize
        
        // Capture screenshot AFTER scrolling
        guard let afterScrollScreenshot = client.captureWindow(windowName: windowName) else {
            aestheticSafePrint("Failed to capture screenshot after scroll")
            break
        }
        
        // Compare with previous screenshot to detect if we've reached the bottom
        if let beforeScreenshot = beforeScrollScreenshot {
            let isSameAsBeforeScroll = client.compareScreenshots(beforeScreenshot, afterScrollScreenshot, threshold: 0.85)
            
            if isSameAsBeforeScroll {
                consecutiveSameScreenshots += 1
                similarScrollCycles.append(scrollCount) // Track this cycle as similar
                aestheticSafePrint("\u{1F534} Screenshot unchanged after scroll (\(consecutiveSameScreenshots)/2)")
                
                // Ensure iPhone Mirroring has focus when screenshots are identical
                if consecutiveSameScreenshots == 1 {
                    ensureIPhoneMirroringFocus()
                }
                
                if consecutiveSameScreenshots >= 2 {
                    aestheticSafePrint("\u{1F3C1} Reached bottom of profile (2 consecutive identical screenshots)")
                    break
                }
            } else {
                consecutiveSameScreenshots = 0
                aestheticSafePrint("\u{1F7E2} New content detected, continuing scroll")
            }
        }
        
        // Process the current screen content
        if let result = client.captureAndProcessWindow(windowName: windowName) {
            let ocrText = client.getAllText(from: result.ocrResults)
            
            if !ocrText.isEmpty {
                scrollData["scroll_\(scrollCount)"] = ocrText
                aestheticSafePrint("\u{1F4DD} Captured text data (\(ocrText.count) chars)")
                aestheticSafePrint("Preview: \(String(ocrText.prefix(100))...)")
            } else {
                scrollData["scroll_\(scrollCount)"] = "No text content captured"
                aestheticSafePrint("\u{26A0} No text content captured")
            }
            
            // Save extracted photos
            if !result.extractedPhotos.isEmpty {
                let savedMetadata = client.savePhotosToSession(result.extractedPhotos, scrollIndex: scrollCount)
                photoMetadata.append(contentsOf: savedMetadata)
                
                let personPhotoCount = result.extractedPhotos.filter { $0.personDetection?.hasPerson == true }.count
                aestheticSafePrint("\u{1F4F7} Extracted \(result.extractedPhotos.count) photos (\(personPhotoCount) with people)")
                
                // Log person detection details
                for photo in result.extractedPhotos {
                    if let personDetection = photo.personDetection, personDetection.hasPerson {
                        aestheticSafePrint("  \u{1F4F8} \(photo.filename): \(personDetection.personCount) person(s) (\(String(format: "%.1f%%", personDetection.confidence * 100)))")
                    } else {
                        aestheticSafePrint("  \u{1F5BC} \(photo.filename): No person detected")
                    }
                }
            }
            
            // Check for iPhone in Use message
            client.checkIPhoneInUseAndHandle(ocrResults: result.ocrResults)
        }
        
        // Small delay between scrolls
        Thread.sleep(forTimeInterval: scrollDelay)
    }
    
    if scrollCount >= maxScrollAttempts {
        print("\u{1F6D1} Reached maximum scroll attempts (\(maxScrollAttempts))")
    }
    
    // Retroactively clean up duplicate photos from similar scroll cycles
    if !similarScrollCycles.isEmpty {
        aestheticSafePrint("\u{1F9F9} Cleaning up duplicate photos from similar scroll cycles: \(similarScrollCycles)")
        cleanupDuplicatePhotos(from: similarScrollCycles, photoMetadata: &photoMetadata, client: client)
    }
    
    aestheticSafePrint("\u{1F3C1} Profile scroll complete! Processed \(scrollCount) scroll sections")
    aestheticSafePrint("\u{1F4CA} Total photos extracted: \(photoMetadata.count)")
    let personPhotos = photoMetadata.filter { $0.personDetection?.hasPerson == true }.count
    let soloPhotos = photoMetadata.filter { $0.isSinglePerson }.count
    aestheticSafePrint("\u{1F465} Photos with people: \(personPhotos)/\(photoMetadata.count)")
    aestheticSafePrint("\u{1F464} Solo person photos: \(soloPhotos)/\(photoMetadata.count)")
    
    // Call Vision API for profile analysis if we have person photos
    if personPhotos > 0, let session = client.getCurrentSession() {
        aestheticSafePrint("\n🤖 Initiating \(visionProvider == "grok" ? "Grok" : "OpenAI") Vision API analysis...")
        let photosDir = client.getSessionManager().getPhotosDirectory(for: session.sessionId).path

        // Build criterion based on user input
        let criterion: String
        if let config = config, !config.initialization.userCriteria.isEmpty {
            criterion = "Based on the user's preference: \(config.initialization.userCriteria). Analyze this dating profile and determine compatibility."
        } else {
            criterion = "Happy, Upbeat, and Smiling"
        }

        // Concatenate all OCR text from the scrolling session
        let concatenatedOCRText = scrollData.values.joined(separator: "\n\n")

        let visionResult = client.callVisionProcessor(photosDir: photosDir, criterion: criterion, provider: visionProvider, isAesthetic: isAesthetic, ocrText: concatenatedOCRText.isEmpty ? nil : concatenatedOCRText)
        
        if let result = visionResult {
            // Convert scrollData to ScrollData format
            let scrollDataArray = scrollData.map { (key, value) in 
                let scrollIndex = Int(key.replacingOccurrences(of: "scroll_", with: "")) ?? 0
                return ScrollData(
                    scrollIndex: scrollIndex,
                    ocrText: value,
                    photoCount: photoMetadata.filter { $0.scrollIndex == scrollIndex }.count,
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )
            }.sorted { $0.scrollIndex < $1.scrollIndex }
            
            // Store the analysis in session metadata
            let profileData = ProfileData(
                sessionId: session.sessionId,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                scrollData: scrollDataArray,
                extractedPhotos: photoMetadata,
                visionAnalysis: result
            )
            
            client.getSessionManager().saveProfileData(profileData)
            
            print("💾 Vision analysis saved to profile data")
            return result
        } else {
            print("⚠️ Vision analysis failed - proceeding without AI input")
            return nil
        }
    } else {
        print("⚠️ No person photos found - skipping Vision analysis")
        return nil
    }
}

func performScrollAndCaptureData(scrollCount: Int, scrollData: inout [String: String], client: VisionOCRClient, windowName: String, photoMetadata: inout [PhotoMetadata]) {
    if let windowRect = client.getWindowPosition(windowName: windowName) {
        let centerX = windowRect.origin.x + windowRect.width / 2
        let centerY = windowRect.origin.y + windowRect.height / 2
        
        let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: centerX, y: centerY), mouseButton: .left)
        mouseMoveEvent?.post(tap: .cghidEventTap)
        
        // Slower, more deliberate scrolling for better capture
        for _ in 1...3 {
            simulateMouseWheelScroll(scrollAmount: -150)
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        print("Scrolling slowly for better capture...")
    } else {
        print("Could not find window position")
    }

    Thread.sleep(forTimeInterval: 2) // Wait for content to stabilize

    // Capture and process the current screen
    if let result = client.captureAndProcessWindow(windowName: windowName) {
        let ocrText = client.getAllText(from: result.ocrResults)
        
        if !ocrText.isEmpty {
            scrollData["after_scroll_\(scrollCount)"] = ocrText
            print("Captured scroll data \(scrollCount):")
            print("SCROLL \(scrollCount) DATA:")
            print(String(repeating: "=", count: 50))
            print(ocrText.prefix(300))
            print(String(repeating: "=", count: 50))
        } else {
            scrollData["after_scroll_\(scrollCount)"] = "No text content captured"
            print("No text content captured after scroll \(scrollCount)")
        }
        
        // Save extracted photos
        if !result.extractedPhotos.isEmpty {
            let savedMetadata = client.savePhotosToSession(result.extractedPhotos, scrollIndex: scrollCount)
            photoMetadata.append(contentsOf: savedMetadata)
            
            let personPhotoCount = result.extractedPhotos.filter { $0.personDetection?.hasPerson == true }.count
            aestheticSafePrint("Extracted and saved \(result.extractedPhotos.count) photos from scroll \(scrollCount) (\(personPhotoCount) with people detected)")

            // Log person detection details
            for photo in result.extractedPhotos {
                if let personDetection = photo.personDetection, personDetection.hasPerson {
                    aestheticSafePrint("  📸 \(photo.filename): \(personDetection.personCount) person(s) detected (confidence: \(String(format: "%.1f%%", personDetection.confidence * 100)))")
                } else {
                    aestheticSafePrint("  🖼️ \(photo.filename): No person detected")
                }
            }
        }
        
        // Check for iPhone in Use message
        client.checkIPhoneInUseAndHandle(ocrResults: result.ocrResults)
    } else {
        print("Failed to capture and process screen after scroll \(scrollCount)")
    }
}

// MARK: - OpenAI Client
class OpenAIClient {
    let apiKey: String
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func sendCompletion(prompt: String, model: String = "gpt-4o", maxTokens: Int = 4000, completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "Be very concise, funny, romantic"],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": maxTokens
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            completion(.failure(error))
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    completion(.success(content))
                } else {
                    completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to parse API response"])))
                }
            } catch {
                completion(.failure(error))
            }
        }

        task.resume()
    }
}

// MARK: - Hinge Agent
class HingeAgent {
    let keychainService = "com.yourcompany.whatsapp-autoresponder"
    let keychainAccountOpenAI = "OPENAI_API_KEY"
    let keychainAccountElevenLabs = "ELEVENLABS_API_KEY"
    var openAI: OpenAIClient?
    let client: VisionOCRClient
    
    init(client: VisionOCRClient) {
        self.client = client
    }

    func loadAPIKeyFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            if let data = result as? Data,
               let apiKey = String(data: data, encoding: .utf8) {
                return apiKey
            }
        }
        return nil
    }

    func saveAPIKeyToKeychain(_ apiKey: String, account: String) {
        let keyData = apiKey.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("Error saving API key to keychain: \(status)")
        }
    }

    func decideToLikeOrPass(scrollData: [String: String], photoMetadata: [PhotoMetadata]) {
        guard let apiKey = loadAPIKeyFromKeychain(account: keychainAccountOpenAI) else {
            print("Error: API key not found in keychain")
            print("Please enter your OpenAI API key:")
            if let inputApiKey = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !inputApiKey.isEmpty {
                saveAPIKeyToKeychain(inputApiKey, account: keychainAccountOpenAI)
                decideToLikeOrPass(scrollData: scrollData, photoMetadata: photoMetadata)
            } else {
                print("Invalid API key. Exiting.")
            }
            return
        }

        self.openAI = OpenAIClient(apiKey: apiKey)

        let photoInfo = photoMetadata.map { metadata in
            var info = "Photo: \(metadata.filename) (scroll \(metadata.scrollIndex))"
            if let personDetection = metadata.personDetection {
                if personDetection.hasPerson {
                    info += " - Contains \(personDetection.personCount) person(s) (confidence: \(String(format: "%.1f%%", personDetection.confidence * 100)))"
                } else {
                    info += " - No person detected (likely scenery/object)"
                }
            }
            return info
        }.joined(separator: "\n")
        
        let personPhotoCount = photoMetadata.filter { $0.personDetection?.hasPerson == true }.count
        let totalPhotoCount = photoMetadata.count
        
        let prompt = """
        Decide whether to like or pass this Hinge profile. For testing purposes, be more generous with likes (like about 50% of profiles).
        Provide a brief explanation for your decision. Be very concise, funny, sarcastic, like a bro friend giving advice.
        
        Profile text data:
        \(scrollData)
        
        Extracted photos (\(personPhotoCount) with people, \(totalPhotoCount) total):
        \(photoInfo)
        
        Consider: Profiles with more actual person photos tend to be more genuine.
        
        End your response with "[like]" or "[pass]"
        """

        let semaphore = DispatchSemaphore(value: 0)

        openAI?.sendCompletion(prompt: prompt) { [weak self] result in
            defer { semaphore.signal() }
            
            switch result {
            case .success(let content):
                print("\n\(content)\n")
                self?.handleDecision(content, scrollData: scrollData, photoMetadata: photoMetadata)
            case .failure(let error):
                print("Error: API request failed: \(error.localizedDescription)")
            }
        }

        semaphore.wait()
    }

    private func handleDecision(_ response: String, scrollData: [String: String], photoMetadata: [PhotoMetadata]) {
        // Audio feedback (simplified - remove ElevenLabs for now)
        print("Decision: \(response)")
        
        if response.contains("[like]") {
            print("Decision: [like]")
            performClickOnLikeButton(scrollData: scrollData, photoMetadata: photoMetadata)
        } else {
            print("Decision: [pass]")
            performClickOnCrossButton()
        }
    }

    private func performClickOnCrossButton() {
        let windowName = "iPhone Mirroring"

        guard let windowPosition = client.getWindowPosition(windowName: windowName) else {
            print("Could not find window position for window: \(windowName)")
            return
        }

        var clickYPercentage: CGFloat = 0.93

        while true {
            let clickX = windowPosition.origin.x + (windowPosition.width * 0.10)
            let clickY = windowPosition.origin.y + (windowPosition.height * clickYPercentage)

            let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left)
            let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left)
            let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left)

            mouseMoveEvent?.post(tap: .cghidEventTap)
            mouseDownEvent?.post(tap: .cghidEventTap)
            mouseUpEvent?.post(tap: .cghidEventTap)

            print("Clicking on cross button")
            Thread.sleep(forTimeInterval: 7)

            // Use Vision OCR to check for "age" text instead of screenpipe
            if let result = client.captureAndProcessWindow(windowName: windowName) {
                let ageResults = client.searchForText(query: "age", in: result.ocrResults)
                if !ageResults.isEmpty {
                    print("'Age' found, cross button click successful")
                    break
                } else {
                    print("'Age' not found, adjusting click position")
                    clickYPercentage -= 0.05
                }
            }
        }
    }

    private func performClickOnLikeButton(scrollData: [String: String], photoMetadata: [PhotoMetadata]) {
        let windowName = "iPhone Mirroring"

        guard let windowPosition = client.getWindowPosition(windowName: windowName) else {
            print("Could not find window position for window: \(windowName)")
            return
        }

        // Click on the heart icon - based on the screenshot, it's in the bottom right area
        // The heart icon appears to be around 85% from left and 92% from top
        let heartClickX = windowPosition.origin.x + (windowPosition.width * 0.85)
        let heartClickY = windowPosition.origin.y + (windowPosition.height * 0.92)

       aestheticSafePrint("Clicking on heart icon at x: \(heartClickX), y: \(heartClickY)")
        
        let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: heartClickX, y: heartClickY), mouseButton: .left)
        let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: heartClickX, y: heartClickY), mouseButton: .left)
        let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: heartClickX, y: heartClickY), mouseButton: .left)

        mouseMoveEvent?.post(tap: .cghidEventTap)
        mouseDownEvent?.post(tap: .cghidEventTap)
        mouseUpEvent?.post(tap: .cghidEventTap)

       aestheticSafePrint("Heart icon clicked, waiting for response...")
        Thread.sleep(forTimeInterval: 3)

        // Look for message/comment interface using Vision OCR
        var messageInterfaceFound = false
        var attempts = 0
        
        while !messageInterfaceFound && attempts < 10 {
            if let result = client.captureAndProcessWindow(windowName: windowName) {
                let messageResults = client.searchForText(query: "message", in: result.ocrResults)
                let commentResults = client.searchForText(query: "comment", in: result.ocrResults)
                let sendResults = client.searchForText(query: "send", in: result.ocrResults)
                let writeResults = client.searchForText(query: "write", in: result.ocrResults)
                
                if !messageResults.isEmpty || !commentResults.isEmpty || !sendResults.isEmpty || !writeResults.isEmpty {
                    messageInterfaceFound = true
                   aestheticSafePrint("Message interface detected!")
                    
                    // Generate and send message
                    let personPhotoCount = photoMetadata.filter { $0.personDetection?.hasPerson == true }.count
                    let photoInfo = photoMetadata.map { metadata in
                        var info = metadata.filename
                        if let personDetection = metadata.personDetection, personDetection.hasPerson {
                            info += "(person)"
                        }
                        return info
                    }.joined(separator: ", ")
                    
                    let messagePrompt = """
                    Write a confident, funny opening message for this Hinge profile. Max 15 words.
                    Based on profile data: \(scrollData)
                    Photos available: \(photoInfo) (\(personPhotoCount) contain people)
                    
                    Be witty, confident, and engaging. Don't be needy or generic.
                    Reference something specific from their profile if possible.
                    """
                    
                    let semaphore = DispatchSemaphore(value: 0)
                    
                    openAI?.sendCompletion(prompt: messagePrompt) { result in
                        defer { semaphore.signal() }
                        
                        switch result {
                        case .success(let message):
                           aestheticSafePrint("\nGenerated message: \(message)\n")
                            
                            // Click in the message text field and type the message
                            DispatchQueue.main.async {
                                self.clickInMessageFieldAndType(message: message, windowPosition: windowPosition)
                            }
                            
                        case .failure(let error):
                           aestheticSafePrint("Error generating message: \(error)")
                        }
                    }
                    
                    semaphore.wait()
                    break
                    
                } else {
                    attempts += 1
                   aestheticSafePrint("Looking for message interface... attempt \(attempts)/10")
                    Thread.sleep(forTimeInterval: 2)
                }
            }
        }
        
        if !messageInterfaceFound {
           aestheticSafePrint("Message interface not found, like was sent without message")
        }
    }
    
    private func sanitizeComment(_ comment: String) -> String {
        let allowedCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,!?'\"()-@#$%^&*()_+=[]{}\\|;:<>/`~")
        return String(comment.filter { allowedCharacters.contains($0) })
    }

    private func keyCodeForCharacter(_ char: Character) -> CGKeyCode? {
        let keyMap: [Character: CGKeyCode] = [
            "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E,
            "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26,
            "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F,
            "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
            "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10,
            "z": 0x06, " ": 0x31, ".": 0x2F, ",": 0x2B, "!": 0x1E,
            "?": 0x2C, "'": 0x27, "\"": 0x27, "(": 0x26, ")": 0x27,
            "-": 0x1B, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22,
            "^": 0x23, "&": 0x24, "*": 0x25, "_": 0x1B, "+": 0x18,
            "=": 0x18, "[": 0x21, "]": 0x1E, "{": 0x21, "}": 0x1E,
            "\\": 0x2A, "|": 0x2A, ";": 0x29, ":": 0x29, "/": 0x2C,
            "<": 0x2B, ">": 0x2F, "`": 0x32, "~": 0x32,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
            "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D
        ]
        return keyMap[char.lowercased().first ?? char]
    }

    func repeatDecisionLoop() {
        for iteration in 1...100 {
            resetAestheticCounters()
            aestheticSafePrint("\n--- Processing profile \(iteration) ---")

            // Ensure iPhone Mirroring is focused
            aestheticSafePrint("🎯 Ensuring iPhone Mirroring is focused...")
            bringIPhoneMirroringToForeground()
            Thread.sleep(forTimeInterval: 2)
            
            aestheticSafePrint("✅ iPhone Mirroring is focused, proceeding with profile analysis")
            
            // Collect data with Vision Framework
            var scrollData: [String: String] = [:]
            var photoMetadata: [PhotoMetadata] = []
            
            // Initial capture
            if let result = client.captureAndProcessWindow(windowName: "iPhone Mirroring") {
                let initialText = client.getAllText(from: result.ocrResults)
                
                if !initialText.isEmpty {
                    scrollData["initial_screen"] = initialText
                    aestheticSafePrint("📱 Captured initial screen data (\(initialText.count) characters)")
                    aestheticSafePrint("Initial screen content:")
                    aestheticSafePrint(String(repeating: "-", count: 40))
                    aestheticSafePrint(String(initialText.prefix(200)))
                    aestheticSafePrint(String(repeating: "-", count: 40))
                } else {
                    scrollData["initial_screen"] = "No content available"
                    aestheticSafePrint("📱 No initial content captured")
                }
                
                // Save initial photos
                if !result.extractedPhotos.isEmpty {
                    let savedMetadata = client.savePhotosToSession(result.extractedPhotos, scrollIndex: 0)
                    photoMetadata.append(contentsOf: savedMetadata)
                    aestheticSafePrint("Extracted and saved \(result.extractedPhotos.count) photos from initial screen")
                }
            }

            // Scroll to bottom and capture all data
            showAestheticAction("scroll")
            aestheticSafePrint("📜 Scrolling through entire profile to collect comprehensive data...")
            let visionAnalysisResult = scrollToBottomAndCaptureData(scrollData: &scrollData, client: client, windowName: "iPhone Mirroring", photoMetadata: &photoMetadata, scrollDelay: scrollDelay, config: config, isAesthetic: isAestheticMode, visionProvider: visionProvider)

            aestheticSafePrint("✅ Profile data collection complete")
            aestheticSafePrint("📊 Collected \(photoMetadata.count) photos across \(scrollData.count) screens")
            
            if isDumbMode {
                // Show enhanced person detection results but ask for manual decision
                let totalPhotos = photoMetadata.count
                let personPhotos = photoMetadata.filter { $0.personDetection?.hasPerson == true }.count
                let soloPhotos = photoMetadata.filter { $0.isSinglePerson }.count
                let personPhotoRatio = Float(personPhotos) / Float(totalPhotos) * 100
                
                aestheticSafePrint("📊 Enhanced Profile Analysis:")
                aestheticSafePrint("  Total photos: \(totalPhotos)")
                aestheticSafePrint("  Photos with people: \(personPhotos)")
                aestheticSafePrint("  Solo person photos: \(soloPhotos)")
                aestheticSafePrint("  Person photo ratio: \(String(format: "%.1f", personPhotoRatio))%")
                
                // Show filter evaluation
                let filterResult = evaluateProfileFilter(from: photoMetadata, minSoloPhotos: 2)
                aestheticSafePrint("  \(filterResult.reason)")
                aestheticSafePrint("")
                aestheticSafePrint("🤖 DUMB MODE: Automatically swiping RIGHT after profile analysis")
                performSwipeRight(client: client, windowName: "iPhone Mirroring", config: config, isAesthetic: isAestheticMode)
            } else {
                showAestheticAction("think")
                aestheticSafePrint("🤖 Making decision based on Vision AI analysis...")
                
                // Use vision AI result if available, otherwise fall back to photo analysis
                if let visionResult = visionAnalysisResult,
                   let decision = visionResult["decision"] as? String {
                    
                    aestheticSafePrint("🧠 Vision AI Decision: \(decision)")
                    if let reasoning = visionResult["reasoning"] as? String {
                        // Show reasoning only if --reasoning flag is enabled
                        if showReasoning {
                            let cleanReasoning = extractReasoningFromResponse(reasoning)
                            // For aesthetic mode, show clean reasoning
                            showAestheticReasoning(reasoning)
                            aestheticSafePrint("💭 Reasoning: \(cleanReasoning)")
                        }
                    }
                    if let confidence = visionResult["confidence"] as? Double {
                        aestheticSafePrint("📊 Confidence: \(String(format: "%.2f", confidence))")
                    }
                    
                    // Perform swipe action based on vision AI decision
                    if decision.uppercased() == "YES" {
                        aestheticSafePrint("✅ Vision AI says YES - swiping right")
                        performSwipeRight(client: client, windowName: "iPhone Mirroring", config: config, isAesthetic: isAestheticMode)
                    } else {
                        aestheticSafePrint("❌ Vision AI says NO - swiping left")
                        performSwipeLeft(client: client, windowName: "iPhone Mirroring", config: config, isAesthetic: isAestheticMode)
                    }
                } else {
                   aestheticSafePrint("⚠️ No vision analysis available - falling back to photo analysis...")
                    
                    // Fallback to enhanced logic with configurable filter
                    let minSoloPhotos = arguments.contains("--filter") ? 2 : 0
                    let enforceFilter = arguments.contains("--filter")
                    let decision = makeMajorityDecision(from: photoMetadata, minSoloPhotos: minSoloPhotos, enforceFilter: enforceFilter)
                    
                    // Log filter result
                    if decision.filterResult.shouldFilter && !enforceFilter {
                       aestheticSafePrint("⚠️  Profile would be filtered but continuing (use --filter flag to enforce)")
                    }
                    
                    // Perform swipe action based on fallback decision
                    if decision.shouldLike {
                        performSwipeRight(client: client, windowName: "iPhone Mirroring", config: config, isAesthetic: isAestheticMode)
                    } else {
                        performSwipeLeft(client: client, windowName: "iPhone Mirroring", config: config, isAesthetic: isAestheticMode)
                    }
                }
            }
            
            aestheticSafePrint("⏭️  Moving to next profile...")
            Thread.sleep(forTimeInterval: 3)
        }
    }

    func clickInMessageFieldAndType(message: String, windowPosition: CGRect) {
        // Message field coordinates: Center-bottom area (50% from left, 85% from top)
        let messageFieldX = windowPosition.origin.x + (windowPosition.width * 0.50)
        let messageFieldY = windowPosition.origin.y + (windowPosition.height * 0.85)

        print("Clicking message field at x: \(messageFieldX), y: \(messageFieldY)")

        // Click in message field
        let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: messageFieldX, y: messageFieldY), mouseButton: .left)
        let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: messageFieldX, y: messageFieldY), mouseButton: .left)
        let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: messageFieldX, y: messageFieldY), mouseButton: .left)

        mouseMoveEvent?.post(tap: .cghidEventTap)
        mouseDownEvent?.post(tap: .cghidEventTap)
        mouseUpEvent?.post(tap: .cghidEventTap)

        // Wait a moment for the field to focus
        Thread.sleep(forTimeInterval: 0.5)

        // Type the message
        print("Typing message: \(message)")

        // Convert message to key events and type it
        for character in message {
            if let keyCode = characterToKeyCode(character) {
                let source = CGEventSource(stateID: .hidSystemState)

                // Handle uppercase characters
                let isUppercase = character.isUppercase

                if isUppercase {
                    // Press shift down
                    let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true) // Left shift
                    shiftDown?.post(tap: .cghidEventTap)
                }

                // Press the actual key
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

                keyDown?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.05) // Small delay between key events
                keyUp?.post(tap: .cghidEventTap)

                if isUppercase {
                    // Release shift
                    let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) // Left shift
                    shiftUp?.post(tap: .cghidEventTap)
                }

                Thread.sleep(forTimeInterval: 0.05) // Small delay between characters
            } else if character == " " {
                // Handle space character
                let source = CGEventSource(stateID: .hidSystemState)
                let spaceDown = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true) // Space key
                let spaceUp = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)

                spaceDown?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.05)
                spaceUp?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        print("✅ Message typed successfully")

        // Optionally press enter to send the message
        // let source = CGEventSource(stateID: .hidSystemState)
        // let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true) // Return key
        // let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        // enterDown?.post(tap: .cghidEventTap)
        // enterUp?.post(tap: .cghidEventTap)
    }

    private func characterToKeyCode(_ character: Character) -> CGKeyCode? {
        let lowercaseChar = character.lowercased().first!

        switch lowercaseChar {
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "=": return 24
        case "9": return 25
        case "7": return 26
        case "-": return 27
        case "8": return 28
        case "0": return 29
        case "]": return 30
        case "o": return 31
        case "u": return 32
        case "[": return 33
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "'": return 39
        case "k": return 40
        case ";": return 41
        case "\\": return 42
        case ",": return 43
        case "/": return 44
        case "n": return 45
        case "m": return 46
        case ".": return 47
        case "`": return 50
        default: return nil
        }
    }
}

// MARK: - Configuration Management
func loadConfig() -> Config {
    let configPath = FileManager.default.currentDirectoryPath + "/config.json"

    guard let data = FileManager.default.contents(atPath: configPath) else {
        print("⚠️ config.json not found, using default values")
        return getDefaultConfig()
    }

    do {
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        print("⚠️ Error parsing config.json: \(error)")
        print("⚠️ Using default values")
        return getDefaultConfig()
    }
}

func getDefaultConfig() -> Config {
    return Config(
        defaults: Config.DefaultConfig(
            visionProvider: "grok",
            scrollDelay: 0.4,
            duplicateDetection: true,
            duplicateThreshold: 0.4,
            markMode: false,
            filterMode: false,
            testMode: false,
            dumbMode: false,
            aestheticMode: true
        ),
        initialization: Config.InitializationConfig(
            analysisType: "both",
            userCriteria: "",
            skipSetup: false
        ),
        ui: Config.UIConfig(
            aestheticOutput: Config.UIConfig.AestheticOutput(
                scrolling: "Scrolling...",
                thinking: "Thinking...",
                swipingRight: "Swiping Right",
                swipingLeft: "Swiping Left"
            )
        )
    )
}

func updateConfigWithUserInput(config: inout Config) {
    print("🔧 Configuration Setup")
    print("======================")

    // Dumb mode selection - FIRST QUESTION
    print("Do you want to use dumb mode?")
    print("1. No - Use AI-powered decision making (default)")
    print("2. Yes - Auto-swipe RIGHT after profile analysis")
    print("Enter choice (1-2): ", terminator: "")

    var isDumbModeEnabled = false
    if let input = readLine(), let choice = Int(input) {
        isDumbModeEnabled = (choice == 2)
        config = Config(
            defaults: Config.DefaultConfig(
                visionProvider: config.defaults.visionProvider,
                scrollDelay: config.defaults.scrollDelay,
                duplicateDetection: config.defaults.duplicateDetection,
                duplicateThreshold: config.defaults.duplicateThreshold,
                markMode: config.defaults.markMode,
                filterMode: config.defaults.filterMode,
                testMode: config.defaults.testMode,
                dumbMode: isDumbModeEnabled,
                aestheticMode: config.defaults.aestheticMode
            ),
            initialization: config.initialization,
            ui: config.ui
        )
    }

    // Skip other questions if dumb mode is enabled
    if isDumbModeEnabled {
        print("\n✅ Configuration complete!")
        print("🤖 Dumb mode: Enabled - Will auto-swipe RIGHT after profile analysis")
        print("")
        return
    }

    // Analysis type selection - ONLY if not in dumb mode
    print("\nWhat type of analysis would you like to use?")
    print("1. Text only")
    print("2. Images only")
    print("3. Both text and images (recommended)")
    print("Enter choice (1-3): ", terminator: "")

    if let input = readLine(), let choice = Int(input) {
        switch choice {
        case 1:
            config = Config(
                defaults: config.defaults,
                initialization: Config.InitializationConfig(
                    analysisType: "text",
                    userCriteria: config.initialization.userCriteria,
                    skipSetup: config.initialization.skipSetup
                ),
                ui: config.ui
            )
        case 2:
            config = Config(
                defaults: config.defaults,
                initialization: Config.InitializationConfig(
                    analysisType: "images",
                    userCriteria: config.initialization.userCriteria,
                    skipSetup: config.initialization.skipSetup
                ),
                ui: config.ui
            )
        case 3:
            config = Config(
                defaults: config.defaults,
                initialization: Config.InitializationConfig(
                    analysisType: "both",
                    userCriteria: config.initialization.userCriteria,
                    skipSetup: config.initialization.skipSetup
                ),
                ui: config.ui
            )
        default:
            print("Invalid choice, using 'both' as default")
        }
    }

    // User criteria input - ONLY if not in dumb mode
    print("\nWhat are you looking for in a potential match?")
    print("(This will help guide the AI's decision-making)")
    print("Enter your criteria: ", terminator: "")

    if let criteria = readLine(), !criteria.isEmpty {
        config = Config(
            defaults: config.defaults,
            initialization: Config.InitializationConfig(
                analysisType: config.initialization.analysisType,
                userCriteria: criteria,
                skipSetup: config.initialization.skipSetup
            ),
            ui: config.ui
        )
    }

    print("\n✅ Configuration complete!")
    print("📊 Analysis type: \(config.initialization.analysisType)")
    print("🎯 User criteria: \(config.initialization.userCriteria.isEmpty ? "None specified" : config.initialization.userCriteria)")
    print("🤖 Dumb mode: Disabled")
    print("")
}

// MARK: - Main Execution
// Load configuration
var config = loadConfig()
let arguments = CommandLine.arguments

// Override config with command line arguments (for backward compatibility)
let isTestMode = arguments.contains("--test") || arguments.contains("-t") || config.defaults.testMode
var isDumbMode = arguments.contains("--dumb") || arguments.contains("-d") || config.defaults.dumbMode
let isDuplicateDetectionEnabled = arguments.contains("--dedupe") || config.defaults.duplicateDetection
let isMarkMode = arguments.contains("--mark-mode") || config.defaults.markMode
let isFilterMode = arguments.contains("--filter") || config.defaults.filterMode
let isAestheticMode = arguments.contains("--aesthetic") || config.defaults.aestheticMode
let showReasoning = arguments.contains("--reasoning") || arguments.contains("-r")

// Parse scroll timing flag (command line overrides config)
let scrollDelay: Double = {
    if let scrollDelayIndex = arguments.firstIndex(of: "--scroll-delay"),
       scrollDelayIndex + 1 < arguments.count,
       let delay = Double(arguments[scrollDelayIndex + 1]) {
        return delay
    }
    return config.defaults.scrollDelay
}()

// Vision API provider selection (command line overrides config)
let visionProvider: String = {
    if arguments.contains("--grok") {
        return "grok"
    } else if arguments.contains("--openai") {
        return "openai"
    } else {
        return config.defaults.visionProvider
    }
}()

// Configurable duplicate detection threshold (command line overrides config)
var duplicateThreshold: Float = config.defaults.duplicateThreshold
if let thresholdIndex = arguments.firstIndex(of: "--threshold"),
   thresholdIndex + 1 < arguments.count,
   let customThreshold = Float(arguments[thresholdIndex + 1]) {
    duplicateThreshold = customThreshold
    print("🎯 Custom duplicate threshold: \(duplicateThreshold)")
}

// Set global aesthetic mode variables
globalIsAestheticMode = isAestheticMode
globalConfig = config

// Run initialization if not in test mode and setup not skipped
if !isTestMode && !config.initialization.skipSetup {
    updateConfigWithUserInput(config: &config)
    // Update global config after user input
    globalConfig = config
}

// Recalculate mode flags after configuration update
isDumbMode = arguments.contains("--dumb") || arguments.contains("-d") || config.defaults.dumbMode

// Show configuration
aestheticSafePrint("🤖 Vision API Provider: \(visionProvider.uppercased())")
aestheticSafePrint("⏱️ Scroll delay: \(scrollDelay)s")
aestheticSafePrint("🔍 Duplicate detection: \(isDuplicateDetectionEnabled ? "Enabled" : "Disabled")")
aestheticSafePrint("📊 Analysis type: \(config.initialization.analysisType)")
if !config.initialization.userCriteria.isEmpty {
    aestheticSafePrint("🎯 Looking for: \(config.initialization.userCriteria)")
}

if isTestMode {
    print("🤖 Starting Hinge Agent v2.0 - TEST MODE")
    print("==========================================")
    print("🧠 This will test swipe functionality only")
    fflush(stdout)
    
    // Initialize Vision OCR client for testing
    let client = VisionOCRClient()
    client.start()
    
    // Ensure iPhone Mirroring is focused
    bringIPhoneMirroringToForeground()
    Thread.sleep(forTimeInterval: 2)
    
    // Run swipe tests
    testSwipeActions(client: client, windowName: "iPhone Mirroring")
    
    print("🏁 Test mode complete!")
    exit(0)
}

if isDumbMode {
    print("🤖 Starting Hinge Agent v2.0 - DUMB MODE")
    print("=========================================")
    print("🧠 Auto-swipe RIGHT after enhanced profile analysis")
} else {
    print("🤖 Starting Hinge Agent v2.0 (Vision Framework)")
    print("===============================================")
    if arguments.contains("--filter") {
        print("🔒 FILTER MODE: Auto-passing profiles with <2 solo photos")
    }
}

if isDuplicateDetectionEnabled {
    print("🔍 DUPLICATE DETECTION: Enabled")
    if isMarkMode {
        print("📝 MARK MODE: Keeping both versions for verification")
    } else {
        print("🗑️ REPLACE MODE: Keeping only most complete versions")
    }
}
fflush(stdout)

// Check and start iPhone Mirroring if needed
print("Checking iPhone Mirroring status...")
fflush(stdout)
if isIPhoneMirroringRunning() {
    print("iPhone Mirroring is already running, bringing it to foreground...")
    fflush(stdout)
    bringIPhoneMirroringToForeground()
} else {
    print("iPhone Mirroring is not running. Starting it now...")
    fflush(stdout)
    startIPhoneMirroring()
    print("iPhone Mirroring has been started and loaded")
    fflush(stdout)
}

// Initialize Vision OCR client
print("Creating Vision OCR client...")
fflush(stdout)
let client = VisionOCRClient()

// Start the client
client.start()

aestheticSafePrint("✅ Vision Framework initialized successfully!")
aestheticSafePrint("📱 Session created: \(client.getCurrentSessionId() ?? "unknown")")

// Set up signal handling
signal(SIGINT) { _ in
    aestheticSafePrint("\n🛑 Received interrupt signal, shutting down...")
    client.stop()
    exit(0)
}

// Skip screenpipe dependency - we're now using Vision Framework
aestheticSafePrint("🎯 Using Apple Vision Framework for OCR and image extraction")
aestheticSafePrint("🔍 Ready to analyze Hinge profiles...")

// Initialize Hinge Agent
let hingeAgent = HingeAgent(client: client)

// Start the main decision loop
aestheticSafePrint("🚀 Starting automated Hinge swiping...")
aestheticSafePrint("🤖 AI-powered decision making using Vision API analysis")
aestheticSafePrint("📱 Make sure Hinge is open in iPhone Mirroring")
aestheticSafePrint("📁 Photos organized by type: person/ multi_person/ other/")
aestheticSafePrint("✂️  Multi-person photos auto-cropped to highlight primary person")
aestheticSafePrint("🧠 Available flags:")
aestheticSafePrint("   --test          Test swipe functionality only")
aestheticSafePrint("   --dumb          Auto-swipe RIGHT after profile analysis")
aestheticSafePrint("   --grok          Use Grok Vision API (requires XAI_API_KEY)")
aestheticSafePrint("   --openai        Use OpenAI Vision API (default, requires OPENAI_API_KEY)")
aestheticSafePrint("   --filter        Auto-pass profiles with <2 solo photos (fallback mode)")
aestheticSafePrint("   --dedupe        Enable duplicate photo detection")
aestheticSafePrint("   --mark-mode     Keep both versions when duplicates found (for testing)")
aestheticSafePrint("   --threshold X   Set duplicate detection threshold (default: 0.4, lower = more sensitive)")
aestheticSafePrint("   --scroll-delay X Set delay between scrolls in seconds (default: 1.0, lower = faster)")
aestheticSafePrint("\nPress Ctrl+C to stop\n")

hingeAgent.repeatDecisionLoop()

aestheticSafePrint("🏁 Hinge Agent completed 100 profiles")
