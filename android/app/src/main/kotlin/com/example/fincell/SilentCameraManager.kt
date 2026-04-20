package com.example.fincell

import android.content.Context
import android.net.Uri
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.firebase.storage.FirebaseStorage
import java.io.File
import java.util.concurrent.Executors

class SilentCameraManager(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner
) {

    fun captureFrontCamera(deviceCode: String) {

        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener({

            val cameraProvider = cameraProviderFuture.get()

            val imageCapture = ImageCapture.Builder().build()

            val cameraSelector = CameraSelector.Builder()
                .requireLensFacing(CameraSelector.LENS_FACING_FRONT)
                .build()

            val photoFile = File(
                context.cacheDir,
                "lost_capture_${System.currentTimeMillis()}.jpg"
            )

            val outputOptions = ImageCapture.OutputFileOptions.Builder(photoFile).build()

            imageCapture.takePicture(
                outputOptions,
                Executors.newSingleThreadExecutor(),
                object : ImageCapture.OnImageSavedCallback {

                    override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                        uploadToFirebase(photoFile, deviceCode)
                    }

                    override fun onError(exception: ImageCaptureException) {
                        exception.printStackTrace()
                    }
                }
            )

            cameraProvider.unbindAll()
            cameraProvider.bindToLifecycle(
                lifecycleOwner,
                cameraSelector,
                imageCapture
            )

        }, ContextCompat.getMainExecutor(context))
    }

    private fun uploadToFirebase(file: File, deviceCode: String) {

        val storageRef = FirebaseStorage.getInstance().reference
            .child("lost_images/$deviceCode/${file.name}")

        storageRef.putFile(Uri.fromFile(file))
    }
}