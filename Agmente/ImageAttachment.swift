//
//  ImageAttachment.swift
//  Agmente
//
//  Image attachment model for including images in prompts.
//

import Foundation
import UIKit

/// Represents an image attachment ready to be sent in a prompt.
struct ImageAttachment: Identifiable, Equatable {
    let id: UUID
    let image: UIImage
    let mimeType: String
    let base64Data: String
    
    /// Original file size in bytes (before compression).
    let originalSize: Int
    
    /// Compressed size in bytes (base64 encoded).
    var compressedSize: Int {
        base64Data.count
    }
    
    /// Human-readable size string.
    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(compressedSize), countStyle: .file)
    }
    
    /// Creates a thumbnail for preview display.
    func thumbnail(maxSize: CGFloat = 80) -> UIImage {
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let thumbnail = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        
        return thumbnail
    }
    
    static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Image Processing

enum ImageProcessor {
    /// Maximum image dimension (width or height) before resizing.
    static let maxDimension: CGFloat = 1024
    
    /// JPEG compression quality for images.
    static let jpegQuality: CGFloat = 0.8
    
    /// Maximum number of attachments allowed per prompt.
    static let maxAttachments: Int = 5
    
    /// Creates an ImageAttachment from a UIImage, with optional resizing and compression.
    /// - Parameters:
    ///   - image: The source image.
    ///   - resize: Whether to resize large images.
    /// - Returns: An ImageAttachment ready for sending, or nil if encoding fails.
    static func processImage(_ image: UIImage, resize: Bool = true) -> ImageAttachment? {
        let originalData = image.pngData() ?? image.jpegData(compressionQuality: 1.0)
        let originalSize = originalData?.count ?? 0
        
        // Resize if needed
        let processedImage: UIImage
        if resize && (image.size.width > maxDimension || image.size.height > maxDimension) {
            processedImage = resizeImage(image, maxDimension: maxDimension)
        } else {
            processedImage = image
        }
        
        // Determine format and encode
        // Prefer JPEG for photos (smaller), PNG for images with transparency
        let (data, mimeType) = encodeImage(processedImage)
        
        guard let imageData = data else {
            return nil
        }
        
        let base64String = imageData.base64EncodedString()
        
        return ImageAttachment(
            id: UUID(),
            image: processedImage,
            mimeType: mimeType,
            base64Data: base64String,
            originalSize: originalSize
        )
    }
    
    /// Resizes an image to fit within the specified maximum dimension.
    private static func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    /// Encodes an image to data with appropriate format detection.
    private static func encodeImage(_ image: UIImage) -> (Data?, String) {
        // Check if image has alpha channel (transparency)
        if hasAlphaChannel(image) {
            // Use PNG to preserve transparency
            return (image.pngData(), "image/png")
        } else {
            // Use JPEG for smaller file size
            return (image.jpegData(compressionQuality: jpegQuality), "image/jpeg")
        }
    }
    
    /// Checks if an image has an alpha channel.
    private static func hasAlphaChannel(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let alphaInfo = cgImage.alphaInfo
        return alphaInfo == .first || alphaInfo == .last ||
               alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
    }
}

// MARK: - ChatMessage Image Storage

/// Lightweight image data for display in chat history (thumbnail only).
struct ChatImageData: Identifiable, Equatable {
    let id: UUID
    let thumbnail: UIImage
    let mimeType: String
    
    /// Creates a ChatImageData from an ImageAttachment (for storing in chat history).
    init(from attachment: ImageAttachment) {
        self.id = attachment.id
        self.thumbnail = attachment.thumbnail(maxSize: 200) // Larger thumbnail for chat display
        self.mimeType = attachment.mimeType
    }
    
    static func == (lhs: ChatImageData, rhs: ChatImageData) -> Bool {
        lhs.id == rhs.id
    }
}