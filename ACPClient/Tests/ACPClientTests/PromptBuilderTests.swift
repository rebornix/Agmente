import XCTest
import ACP
@testable import ACPClient

final class PromptBuilderTests: XCTestCase {
    
    // MARK: - Text Content Tests
    
    func testBuildWithTextOnly() {
        let result = ACPPromptBuilder.build(text: "Hello, world!")
        
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.contents.count, 1)
        XCTAssertTrue(result.warnings.isEmpty)
        
        if case .text(let text) = result.contents[0] {
            XCTAssertEqual(text, "Hello, world!")
        } else {
            XCTFail("Expected text content")
        }
    }
    
    func testBuildWithEmptyText() {
        let result = ACPPromptBuilder.build(text: "")
        
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.contents.isEmpty)
    }
    
    func testBuildWithWhitespaceOnlyText() {
        let result = ACPPromptBuilder.build(text: "   \n\t  ")
        
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.contents.isEmpty)
    }
    
    func testBuildPreservesOriginalTextWithWhitespace() {
        // Text with leading/trailing whitespace should be preserved in the content
        // but trimming is only for checking emptiness
        let result = ACPPromptBuilder.build(text: "  Hello  ")
        
        XCTAssertTrue(result.isValid)
        if case .text(let text) = result.contents[0] {
            XCTAssertEqual(text, "  Hello  ")
        } else {
            XCTFail("Expected text content")
        }
    }
    
    // MARK: - Image Content Tests
    
    func testBuildWithImage() {
        let image = ACPImageInput(mimeType: "image/jpeg", base64Data: "abc123==")
        let result = ACPPromptBuilder.build(text: "", images: [image])
        
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.contents.count, 1)
        
        if case .image(let mimeType, let data) = result.contents[0] {
            XCTAssertEqual(mimeType, "image/jpeg")
            XCTAssertEqual(data, "abc123==")
        } else {
            XCTFail("Expected image content")
        }
    }
    
    func testBuildWithTextAndImages() {
        let images = [
            ACPImageInput(mimeType: "image/png", base64Data: "png-data"),
            ACPImageInput(mimeType: "image/jpeg", base64Data: "jpeg-data")
        ]
        let result = ACPPromptBuilder.build(text: "Check these images", images: images)
        
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.contents.count, 3) // 1 text + 2 images
        
        // First should be text
        if case .text(let text) = result.contents[0] {
            XCTAssertEqual(text, "Check these images")
        } else {
            XCTFail("Expected text content first")
        }
        
        // Then images
        if case .image(let mimeType, _) = result.contents[1] {
            XCTAssertEqual(mimeType, "image/png")
        } else {
            XCTFail("Expected image content")
        }
        
        if case .image(let mimeType, _) = result.contents[2] {
            XCTAssertEqual(mimeType, "image/jpeg")
        } else {
            XCTFail("Expected image content")
        }
    }
    
    // MARK: - Capability Validation Tests
    
    func testBuildWithImageAndNoImageCapability() {
        let capabilities = PromptCapabilityState(audio: false, image: false, embeddedContext: false)
        let image = ACPImageInput(mimeType: "image/jpeg", base64Data: "data")
        let result = ACPPromptBuilder.build(text: "test", images: [image], capabilities: capabilities)
        
        // Image should still be included, but with a warning
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.contents.count, 2)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("does not support image prompts"))
    }
    
    func testBuildWithImageAndImageCapability() {
        let capabilities = PromptCapabilityState(audio: false, image: true, embeddedContext: false)
        let image = ACPImageInput(mimeType: "image/jpeg", base64Data: "data")
        let result = ACPPromptBuilder.build(text: "test", images: [image], capabilities: capabilities)
        
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.warnings.isEmpty)
    }
    
    func testBuildWithAudioAndNoAudioCapability() {
        let capabilities = PromptCapabilityState(audio: false, image: false, embeddedContext: false)
        let audio = ACPAudioInput(mimeType: "audio/mp3", base64Data: "audio-data")
        let result = ACPPromptBuilder.build(
            text: "transcribe this",
            audio: [audio],
            capabilities: capabilities
        )
        
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("does not support audio prompts"))
    }
    
    func testBuildWithContextAndNoContextCapability() {
        let capabilities = PromptCapabilityState(audio: false, image: false, embeddedContext: false)
        let context = ACPContextInput(text: "some code", source: "file.swift")
        let result = ACPPromptBuilder.build(
            text: "explain this",
            contexts: [context],
            capabilities: capabilities
        )
        
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("does not support embedded context"))
    }
    
    // MARK: - Full Build Tests
    
    func testBuildWithAllContentTypes() {
        let capabilities = PromptCapabilityState(audio: true, image: true, embeddedContext: true)
        let result = ACPPromptBuilder.build(
            text: "Analyze all of this",
            images: [ACPImageInput(mimeType: "image/png", base64Data: "img")],
            audio: [ACPAudioInput(mimeType: "audio/wav", base64Data: "wav")],
            contexts: [ACPContextInput(text: "code snippet", source: "main.swift")],
            capabilities: capabilities
        )
        
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.contents.count, 4)
        XCTAssertTrue(result.warnings.isEmpty)
        
        // Verify order: text, images, audio, contexts
        if case .text = result.contents[0] {} else { XCTFail("Expected text first") }
        if case .image = result.contents[1] {} else { XCTFail("Expected image second") }
        if case .audio = result.contents[2] {} else { XCTFail("Expected audio third") }
        if case .context = result.contents[3] {} else { XCTFail("Expected context fourth") }
    }
    
    // MARK: - JSON Conversion Tests
    
    func testTextContentToJSON() {
        let content = ACPPromptContent.text("Hello")
        let json = content.toJSON()
        
        guard case .object(let obj) = json else {
            XCTFail("Expected object")
            return
        }
        
        XCTAssertEqual(obj["type"]?.stringValue, "text")
        XCTAssertEqual(obj["text"]?.stringValue, "Hello")
    }
    
    func testImageContentToJSON() {
        let content = ACPPromptContent.image(mimeType: "image/png", base64Data: "abc123")
        let json = content.toJSON()
        
        guard case .object(let obj) = json else {
            XCTFail("Expected object")
            return
        }
        
        XCTAssertEqual(obj["type"]?.stringValue, "image")
        XCTAssertEqual(obj["mimeType"]?.stringValue, "image/png")
        XCTAssertEqual(obj["data"]?.stringValue, "abc123")
    }
    
    func testAudioContentToJSON() {
        let content = ACPPromptContent.audio(mimeType: "audio/mp3", base64Data: "mp3data")
        let json = content.toJSON()
        
        guard case .object(let obj) = json else {
            XCTFail("Expected object")
            return
        }
        
        XCTAssertEqual(obj["type"]?.stringValue, "audio")
        XCTAssertEqual(obj["mimeType"]?.stringValue, "audio/mp3")
        XCTAssertEqual(obj["data"]?.stringValue, "mp3data")
    }
    
    func testContextContentToJSON() {
        let content = ACPPromptContent.context(text: "code here", source: "file.swift")
        let json = content.toJSON()
        
        guard case .object(let obj) = json else {
            XCTFail("Expected object")
            return
        }
        
        XCTAssertEqual(obj["type"]?.stringValue, "context")
        XCTAssertEqual(obj["text"]?.stringValue, "code here")
        XCTAssertEqual(obj["source"]?.stringValue, "file.swift")
    }
    
    func testContextContentToJSONWithoutSource() {
        let content = ACPPromptContent.context(text: "code here", source: nil)
        let json = content.toJSON()
        
        guard case .object(let obj) = json else {
            XCTFail("Expected object")
            return
        }
        
        XCTAssertEqual(obj["type"]?.stringValue, "context")
        XCTAssertEqual(obj["text"]?.stringValue, "code here")
        XCTAssertNil(obj["source"])
    }
    
    func testToJSONArray() {
        let result = ACPPromptBuilder.build(
            text: "Hello",
            images: [ACPImageInput(mimeType: "image/png", base64Data: "data")]
        )
        
        let jsonArray = result.toJSONArray()
        XCTAssertEqual(jsonArray.count, 2)
    }
    
    // MARK: - Debug Description Tests
    
    func testTextDebugDescription() {
        let content = ACPPromptContent.text("Short text")
        XCTAssertEqual(content.debugDescription, "{type:\"text\", text:\"Short text\"}")
    }
    
    func testLongTextDebugDescriptionTruncates() {
        let longText = String(repeating: "a", count: 100)
        let content = ACPPromptContent.text(longText)
        XCTAssertTrue(content.debugDescription.contains("..."))
        XCTAssertTrue(content.debugDescription.count < longText.count + 50)
    }
    
    func testImageDebugDescription() {
        let content = ACPPromptContent.image(mimeType: "image/png", base64Data: "abc123")
        XCTAssertEqual(content.debugDescription, "{type:\"image\", mimeType:\"image/png\", data:\"<6 chars>\"}")
    }
    
    // MARK: - Validation Tests
    
    func testValidateEmptyResult() {
        let result = ACPPromptBuilder.build(text: "")
        let error = ACPPromptBuilder.validate(result)
        
        XCTAssertNotNil(error)
        XCTAssertEqual(error, "Cannot send empty prompt")
    }
    
    func testValidateValidResult() {
        let result = ACPPromptBuilder.build(text: "Hello")
        let error = ACPPromptBuilder.validate(result)
        
        XCTAssertNil(error)
    }
    
    // MARK: - Payload Creation Tests
    
    func testMakePayloadFromValidResult() {
        let result = ACPPromptBuilder.build(text: "Hello")
        let payload = result.makePayload(sessionId: "session-123")
        
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.sessionId, "session-123")
        XCTAssertEqual(payload?.prompt.count, 1)
    }
    
    func testMakePayloadFromInvalidResult() {
        let result = ACPPromptBuilder.build(text: "")
        let payload = result.makePayload(sessionId: "session-123")
        
        XCTAssertNil(payload)
    }
    
    func testMakePayloadWithAttachments() {
        let result = ACPPromptBuilder.build(text: "Hello")
        let attachments: [String: ACP.Value] = ["key": .string("value")]
        let payload = result.makePayload(sessionId: "session-123", attachments: attachments)
        
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.attachments["key"]?.stringValue, "value")
    }
    
    // MARK: - Multiple Warnings Tests
    
    func testMultipleCapabilityWarnings() {
        let capabilities = PromptCapabilityState(audio: false, image: false, embeddedContext: false)
        let result = ACPPromptBuilder.build(
            text: "test",
            images: [ACPImageInput(mimeType: "image/png", base64Data: "img")],
            audio: [ACPAudioInput(mimeType: "audio/mp3", base64Data: "audio")],
            contexts: [ACPContextInput(text: "code", source: nil)],
            capabilities: capabilities
        )
        
        XCTAssertEqual(result.warnings.count, 3)
    }
}