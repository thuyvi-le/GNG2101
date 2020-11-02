//
//  ViewController.swift
//  ButtonLocator
//
//  Created by Gianluca Coletti on 2020-10-28.
//

import UIKit
import Vision

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        // OBJECT RECOGNITION //

        //Configure camera to use for capture
        private let session = AVCaptureSession()

        //Set up device and session resoltion
        let videoDevice = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back).devices.first
        do {
            deviceInput = try AVCaptureDeviceInput(device: videoDevice!)
        } catch {
            print("Could not create video device input: \(error)")
            return
        }

        /// Original
        /// session.beginConfiguration()
        /// session.sessionPreset = .vga640x480 //See if resolution can be made smaller
        
        if ([session.canSetSessionPreset:AVCaptureSessionPreset640x480]) {
            [session.setSessionPreset:AVCaptureSessionPreset640x480]; //Can also do Low, Med,High and Photo capture preset
        }

        //Add video input to session by adding the camera as a device
        guard session.canAddInput(deviceInput) else {
            print("Could not add video device input to the session")
            session.commitConfiguration()
            return
        }
        session.addInput(deviceInput)

        //Add video output to your session
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            // Add a video data output
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        } else {
            print("Could not add video data output to the session")
            session.commitConfiguration()
            return
        }

        //Processing frame
        let captureConnection = videoDataOutput.connection(with: .video)
        // Always process the frames
        captureConnection?.isEnabled = true
        do {
            try  videoDevice!.lockForConfiguration()
            let dimensions = CMVideoFormatDescriptionGetDimensions((videoDevice?.activeFormat.formatDescription)!)
            bufferSize.width = CGFloat(dimensions.width)
            bufferSize.height = CGFloat(dimensions.height)
            videoDevice!.unlockForConfiguration()
        } catch {
            print(error)
        }

        //Commit session configuration
        session.commitConfiguration()

        //Set up preview layer on view controller
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        rootLayer = previewView.layer
        previewLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(previewLayer)

        //Device orientation
        let curDeviceOrientation = UIDevice.current.orientation
        let exifOrientation: CGImagePropertyOrientation

        switch curDeviceOrientation {
        	// Device oriented vertically, home button on the top
        	case UIDeviceOrientation.portraitUpsideDown: exifOrientation = .left

        	// Device oriented horizontally, home button on the right
        	case UIDeviceOrientation.landscapeLeft: exifOrientation = .upMirrored

        	// Device oriented horizontally, home button on the left
        	case UIDeviceOrientation.landscapeRight: exifOrientation = .down

        	// Device oriented vertically, home button on the bottom
        	case UIDeviceOrientation.portrait: exifOrientation = .up
        	
        	default: exifOrientation = .up
        }

        //Core ML classifier (elevator buttons)
        let visionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL)) //loading model

        let objectRecognition = VNCoreMLRequest(model: visionModel, completionHandler: { (request, error) in
            DispatchQueue.main.async(execute: {
                // perform all the UI updates on the main queue
                if let results = request.results {
                    self.drawVisionRequestResults(results)
                }
            })
        })

        //Parse recognized object observations
        for observation in results where observation is VNRecognizedObjectObservation {
            guard let objectObservation = observation as? VNRecognizedObjectObservation else { continue }

            // Select only the label with the highest confidence.
            let topLabelObservation = objectObservation.labels[0]
            let objectBounds = VNImageRectForNormalizedRect(objectObservation.boundingBox, Int(bufferSize.width), Int(bufferSize.height))
            
            let shapeLayer = self.createRoundedRectLayerWithBounds(objectBounds)
            
            let textLayer = self.createTextSubLayerInBounds(objectBounds, identifier: topLabelObservation.identifier, confidence: topLabelObservation.confidence)
            shapeLayer.addSublayer(textLayer)
            detectionOverlay.addSublayer(shapeLayer)
        }

        // OBJECT TRACKING //

        //Nominate Objects or Rectangles to Track
        var inputObservations = [UUID: VNDetectedObjectObservation]()
        var trackedObjects = [UUID: TrackedPolyRect]()

        switch type {
	        case .object:
	            for rect in self.objectsToTrack {
	                let inputObservation = VNDetectedObjectObservation(boundingBox: rect.boundingBox)
	                inputObservations[inputObservation.uuid] = inputObservation
	                trackedObjects[inputObservation.uuid] = rect
	            }
	        case .rectangle:
	            for rectangleObservation in initialRectObservations {
	                inputObservations[rectangleObservation.uuid] = rectangleObservation
	                let rectColor = TrackedObjectsPalette.color(atIndex: trackedObjects.count)
	                trackedObjects[rectangleObservation.uuid] = TrackedPolyRect(observation: rectangleObservation, color: rectColor)
	            }
        }

        //Track Objects or Rectangles with a Request Handler
        let request: VNTrackingRequest!
        switch type {
	        case .object:
	            request = VNTrackObjectRequest(detectedObjectObservation: inputObservation.value)
	        case .rectangle:
	            guard let rectObservation = inputObservation.value as? VNRectangleObservation else {
	                continue
	            }
	            request = VNTrackRectangleRequest(rectangleObservation: rectObservation)
        }
        request.trackingLevel = trackingLevel

        trackingRequests.append(request)

        try requestHandler.perform(trackingRequests, on: frame, orientation: videoReader.orientation)

        //Interpret tracking results **results property in VNDetectedObjectObservation object describes location in frame

        guard let results = processedRequest.results as? [VNObservation] else {
            continue
        }
        guard let observation = results.first as? VNDetectedObjectObservation else {
            continue
        }
        // Assume threshold = 0.5f
        let rectStyle: TrackedPolyRectStyle = observation.confidence > 0.5 ? .solid : .dashed
        let knownRect = trackedObjects[observation.uuid]!
        switch type {
	        case .object:
	            rects.append(TrackedPolyRect(observation: observation, color: knownRect.color, style: rectStyle))
	        case .rectangle:
	            guard let rectObservation = observation as? VNRectangleObservation else {
	                break
	            }
	            rects.append(TrackedPolyRect(observation: rectObservation, color: knownRect.color, style: rectStyle))
        }

        inputObservations[observation.uuid] = observation //seed next round of tracking
    }

} //End of ViewController

