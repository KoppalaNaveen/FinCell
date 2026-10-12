package com.example.fincell

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.google.firebase.storage.FirebaseStorage
import java.io.File
import java.util.UUID

class SilentCameraManager(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner
) {

    companion object {
        private const val DEFAULT_QUOTA_BYTES: Long = 16106127360L // 15 * 1024^3
    }

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
        val db = FirebaseFirestore.getInstance()

        // 1. Resolve authorized owner UID for this device code
        db.collection("device_codes").document(deviceCode).get()
            .addOnSuccessListener { docSnapshot ->
                val ownerUid = docSnapshot.getString("ownerUid")
                    ?: FirebaseAuth.getInstance().currentUser?.uid
                    ?: ""

                if (ownerUid.isEmpty()) {
                    Log.e("SILENT_CAMERA", "Cannot upload photo: ownerUid is missing for device $deviceCode")
                    markCommandFailed(deviceCode, "Owner UID missing")
                    try { if (file.exists()) file.delete() } catch (_: Exception) {}
                    return@addOnSuccessListener
                }

                val userRef = db.collection("users").document(ownerUid)

                // 2. ATOMIC PRE-UPLOAD QUOTA RESERVATION
                db.runTransaction { transaction ->
                    val userSnap = transaction.get(userRef)
                    val quota = userSnap.getLong("storageQuotaBytes") ?: DEFAULT_QUOTA_BYTES
                    val currentUsed = userSnap.getLong("storageUsedBytes") ?: 0L

                    if (currentUsed + fileSize > quota) {
                        throw IllegalStateException("QUOTA_EXCEEDED")
                    }

                    transaction.update(userRef, "storageQuotaBytes", quota)
                    transaction.update(userRef, "storageUsedBytes", currentUsed + fileSize)
                    transaction.update(userRef, "updatedAt", FieldValue.serverTimestamp())
                    null
                }.addOnSuccessListener {
                    // 3. Reservation granted! Upload file to Firebase Storage
                    val uniqueSuffix = "${System.currentTimeMillis()}_${UUID.randomUUID().toString().take(8)}"
                    val storagePath = "users/$ownerUid/lost_devices/$deviceCode/images/$uniqueSuffix.jpg"
                    val storageRef = FirebaseStorage.getInstance().reference.child(storagePath)

                    storageRef.putFile(Uri.fromFile(file))
                        .addOnSuccessListener {
                            storageRef.downloadUrl.addOnSuccessListener { downloadUri ->
                                val now = Timestamp.now()

                                val photoData = hashMapOf<String, Any>(
                                    "storagePath" to storagePath,
                                    "imageUrl" to downloadUri.toString(),
                                    "timestamp" to now,
                                    "latitude" to (lat ?: 0.0),
                                    "longitude" to (lng ?: 0.0),
                                    "battery" to (battery ?: 0),
                                    "camera" to "front",
                                    "fileSize" to fileSize,
                                    "fileSizeBytes" to fileSize,
                                    "mediaType" to "image",
                                    "ownerUid" to ownerUid,
                                    "deviceCode" to deviceCode,
                                    "commandId" to (commandId ?: "")
                                )

                                // Store in users/{ownerUid}/lost_devices/{deviceCode}/images
                                db.collection("users")
                                    .document(ownerUid)
                                    .collection("lost_devices")
                                    .document(deviceCode)
                                    .collection("images")
                                    .add(photoData)

                                // Also store in device_images/{deviceCode}/photos for existing UI compatibility
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
                                    .set(imageUpdateData, SetOptions.merge())

                                val cmdUpdate = hashMapOf<String, Any>(
                                    "status" to "completed",
                                    "completedAt" to now
                                )
                                db.collection("device_commands")
                                    .document(deviceCode)
                                    .set(cmdUpdate, SetOptions.merge())

                                // Clean up local temporary file
                                try { if (file.exists()) file.delete() } catch (_: Exception) {}
                            }
                        }
                        .addOnFailureListener { e ->
                            Log.e("SILENT_CAMERA", "Photo upload failed: ${e.message}")
                            // Rollback reserved bytes on upload failure
                            rollbackStorage(ownerUid, fileSize)
                            markCommandFailed(deviceCode, "Photo upload failed: ${e.message}")
                            try { if (file.exists()) file.delete() } catch (_: Exception) {}
                        }
                }.addOnFailureListener { e ->
                    Log.e("SILENT_CAMERA", "Storage reservation rejected: ${e.message}")
                    markCommandFailed(deviceCode, "Storage Quota Exceeded (15 GB limit reached)")
                    try { if (file.exists()) file.delete() } catch (_: Exception) {}
                }
            }
            .addOnFailureListener { e ->
                Log.e("SILENT_CAMERA", "Failed to query device code: ${e.message}")
                markCommandFailed(deviceCode, "Device query failed: ${e.message}")
                try { if (file.exists()) file.delete() } catch (_: Exception) {}
            }
    }

    private fun rollbackStorage(ownerUid: String, fileSizeBytes: Long) {
        if (fileSizeBytes <= 0 || ownerUid.isEmpty()) return
        val db = FirebaseFirestore.getInstance()
        val userRef = db.collection("users").document(ownerUid)
        db.runTransaction { transaction ->
            val userSnap = transaction.get(userRef)
            if (userSnap.exists()) {
                val currentUsed = userSnap.getLong("storageUsedBytes") ?: 0L
                val newUsed = Math.max(0L, currentUsed - fileSizeBytes)
                transaction.update(userRef, "storageUsedBytes", newUsed)
                transaction.update(userRef, "updatedAt", FieldValue.serverTimestamp())
            }
            null
        }.addOnFailureListener { e ->
            Log.e("SILENT_CAMERA", "Failed to rollback storage quota: ${e.message}")
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
                .set(failData, SetOptions.merge())
        } catch (_: Exception) {}
    }
}