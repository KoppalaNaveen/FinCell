package com.example.fincell

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.firebase.Timestamp
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.storage.FirebaseStorage
import java.io.File
import java.util.concurrent.Executors

class SilentCameraManager(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner
) {

    fun captureFrontCamera(
        deviceCode: String,
        reason: String = "Periodic Lost Mode Capture",
        lat: Double? = null,
        lng: Double? = null,
        battery: Int? = null,
        commandId: String? = null
    ) {
        try {
            val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

            cameraProviderFuture.addListener({
                try {
                    val cameraProvider = cameraProviderFuture.get()

                    val imageCapture = ImageCapture.Builder().build()

                    val cameraSelector = CameraSelector.Builder()
                        .requireLensFacing(CameraSelector.LENS_FACING_FRONT)
                        .build()

                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        cameraSelector,
                        imageCapture
                    )

                    val outputDirectory = context.cacheDir
                    val photoFile = File(
                        outputDirectory,
                        "IMG_${System.currentTimeMillis()}.jpg"
                    )

                    val outputOptions = ImageCapture.OutputFileOptions.Builder(photoFile).build()

                    imageCapture.takePicture(
                        outputOptions,
                        ContextCompat.getMainExecutor(context),
                        object : ImageCapture.OnImageSavedCallback {
                            override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                                uploadPhoto(deviceCode, photoFile, reason, lat, lng, battery, commandId)
                            }

                            override fun onError(exception: ImageCaptureException) {
                                Log.e("SILENT_CAMERA", "Photo capture failed: ${exception.message}", exception)
                                markCommandFailed(deviceCode, "Camera capture error: ${exception.message}")
                            }
                        }
                    )
                } catch (e: Exception) {
                    Log.e("SILENT_CAMERA", "Camera binding failed: ${e.message}", e)
                    markCommandFailed(deviceCode, "Camera binding failed: ${e.message}")
                }
            }, ContextCompat.getMainExecutor(context))
        } catch (e: Exception) {
            Log.e("SILENT_CAMERA", "Front camera capture error: ${e.message}", e)
            markCommandFailed(deviceCode, "Camera init error: ${e.message}")
        }
    }

    private fun uploadPhoto(
        deviceCode: String,
        file: File,
        reason: String,
        lat: Double?,
        lng: Double?,
        battery: Int?,
        commandId: String?
    ) {
        val fileName = file.name
        val fileSize = file.length()
        val storageRef = FirebaseStorage.getInstance().reference
            .child("lost_images/$deviceCode/${System.currentTimeMillis()}.jpg")

        storageRef.putFile(Uri.fromFile(file))
            .addOnSuccessListener { taskSnapshot ->
                storageRef.downloadUrl.addOnSuccessListener { downloadUri ->
                    val now = Timestamp.now()

                    val photoData = hashMapOf<String, Any>(
                        "imageUrl" to downloadUri.toString(),
                        "timestamp" to now,
                        "latitude" to (lat ?: 0.0),
                        "longitude" to (lng ?: 0.0),
                        "battery" to (battery ?: 0),
                        "camera" to "front",
                        "fileSize" to fileSize,
                        "commandId" to (commandId ?: "")
                    )

                    val db = FirebaseFirestore.getInstance()
                    db.collection("device_images")
                        .document(deviceCode)
                        .collection("photos")
                        .add(photoData)

                    val timelineData = hashMapOf<String, Any>(
                        "imageUrl" to downloadUri.toString(),
                        "fileName" to fileName,
                        "reason" to reason,
                        "timestamp" to now,
                        "lat" to (lat ?: 0.0),
                        "lng" to (lng ?: 0.0),
                        "battery" to (battery ?: 0),
                        "eventType" to "CAMERA_CAPTURE",
                        "description" to "Silent front camera photo captured: $reason"
                    )
                    db.collection("device_timeline")
                        .document(deviceCode)
                        .collection("events")
                        .add(timelineData)

                    val imageUpdateData = hashMapOf<String, Any>(
                        "lastCapturedImageUrl" to downloadUri.toString(),
                        "lastCaptureReason" to reason
                    )
                    db.collection("device_codes")
                        .document(deviceCode)
                        .set(imageUpdateData, com.google.firebase.firestore.SetOptions.merge())

                    val cmdUpdate = hashMapOf<String, Any>(
                        "status" to "completed",
                        "completedAt" to now
                    )
                    db.collection("device_commands")
                        .document(deviceCode)
                        .set(cmdUpdate, com.google.firebase.firestore.SetOptions.merge())

                    // Clean up local temp file
                    try {
                        if (file.exists()) file.delete()
                    } catch (_: Exception) {}
                }
            }
            .addOnFailureListener { e ->
                Log.e("SILENT_CAMERA", "Photo upload failed: ${e.message}")
                markCommandFailed(deviceCode, "Photo upload failed: ${e.message}")
            }
    }

    private fun markCommandFailed(deviceCode: String, reason: String) {
        try {
            val db = FirebaseFirestore.getInstance()
            val failData = hashMapOf<String, Any>(
                "status" to "failed",
                "failureReason" to reason,
                "completedAt" to Timestamp.now()
            )
            db.collection("device_commands")
                .document(deviceCode)
                .set(failData, com.google.firebase.firestore.SetOptions.merge())
        } catch (_: Exception) {}
    }
}