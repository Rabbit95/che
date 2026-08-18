package com.example.quick_usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

private const val ACTION_USB_PERMISSION = "com.example.quick_usb.USB_PERMISSION"

// Patched (nikon_z_control fork): use numeric literals instead of the
// SDK 31+ symbols Build.VERSION_CODES.S / PendingIntent.FLAG_MUTABLE so
// this source compiles even when the machine only has old Android SDK
// platforms installed. Values match the Android source:
//   VERSION_CODES.S              = 31
//   PendingIntent.FLAG_MUTABLE   = 0x02000000
private val pendingIntentFlag =
  if (Build.VERSION.SDK_INT >= 31) {
    0x02000000 or PendingIntent.FLAG_UPDATE_CURRENT
  } else {
    PendingIntent.FLAG_UPDATE_CURRENT
  }

private fun pendingPermissionIntent(context: Context) = PendingIntent.getBroadcast(context, 0, Intent(ACTION_USB_PERMISSION), pendingIntentFlag)

/** QuickUsbPlugin */
class QuickUsbPlugin : FlutterPlugin, MethodCallHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel: MethodChannel

  private var applicationContext: Context? = null
  private var usbManager: UsbManager? = null

  // Patched (nikon_z_control fork): serialize all blocking USB I/O on a
  // dedicated background thread so a stalled bulkTransfer doesn't freeze
  // the Android UI thread → ANR. MethodChannel.Result must be dispatched
  // on the platform (main) thread, so results are hopped back via
  // [mainHandler]. A single-thread executor is intentional: android's
  // UsbDeviceConnection is not thread-safe when the same endpoint is
  // used from multiple threads concurrently.
  private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
    Thread(r, "quick_usb-io").apply { isDaemon = true }
  }
  private val mainHandler = Handler(Looper.getMainLooper())

  private fun postSuccess(result: Result, value: Any?) {
    mainHandler.post { result.success(value) }
  }

  private fun postError(result: Result, code: String, message: String) {
    mainHandler.post { result.error(code, message, null) }
  }

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "quick_usb")
    channel.setMethodCallHandler(this)
    applicationContext = flutterPluginBinding.applicationContext
    usbManager = applicationContext?.getSystemService(Context.USB_SERVICE) as UsbManager
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    usbManager = null
    applicationContext = null
    // Best-effort shutdown of the background thread. shutdownNow() is
    // preferred over shutdown() because a stalled bulkTransfer is
    // uninterruptible from Kotlin land — the thread will exit when its
    // current blocking call unblocks (either by timeout or by us calling
    // usbDeviceConnection.close() from outside).
    ioExecutor.shutdownNow()
  }

  private var usbDevice: UsbDevice? = null
  private var usbDeviceConnection: UsbDeviceConnection? = null

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "getDeviceList" -> {
        val manager = usbManager ?: return result.error("IllegalState", "usbManager null", null)
        val usbDeviceList = manager.deviceList.entries.map {
          mapOf(
            "identifier" to it.key,
            "vendorId" to it.value.vendorId,
            "productId" to it.value.productId,
            "configurationCount" to it.value.configurationCount,
          )
        }
        result.success(usbDeviceList)
      }
      "getDeviceDescription" -> {
        val context = applicationContext ?: return result.error("IllegalState", "applicationContext null", null)
        val manager = usbManager ?: return result.error("IllegalState", "usbManager null", null)
        val identifier = call.argument<Map<String, Any>>("device")!!["identifier"]!!;
        val device = manager.deviceList[identifier] ?: return result.error("IllegalState", "usbDevice null", null)
        val requestPermission = call.argument<Boolean>("requestPermission")!!;

        val hasPermission = manager.hasPermission(device)
        if (requestPermission && !hasPermission) {
          val permissionReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
              context.unregisterReceiver(this)
              val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false);
              result.success(mapOf(
                "manufacturer" to device.manufacturerName,
                "product" to device.productName,
                "serialNumber" to if (granted) device.serialNumber else null,
              ))
            }
          }
          context.registerReceiver(permissionReceiver, IntentFilter(ACTION_USB_PERMISSION))
          manager.requestPermission(device, pendingPermissionIntent(context))
        } else {
          result.success(mapOf(
            "manufacturer" to device.manufacturerName,
            "product" to device.productName,
            "serialNumber" to if (hasPermission) device.serialNumber else null,
          ))
        }
      }
      "hasPermission" -> {
        val manager = usbManager ?: return result.error("IllegalState", "usbManager null", null)
        val identifier = call.argument<String>("identifier")
        val device = manager.deviceList[identifier]
        result.success(manager.hasPermission(device))
      }
      "requestPermission" -> {
        val context = applicationContext ?: return result.error("IllegalState", "applicationContext null", null)
        val manager = usbManager ?: return result.error("IllegalState", "usbManager null", null)
        val identifier = call.argument<String>("identifier")
        val device = manager.deviceList[identifier]
        if (manager.hasPermission(device)) {
          result.success(true)
        } else {
          val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
              context.unregisterReceiver(this)
              val usbDevice = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
              val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
              result.success(granted);
            }
          }
          context.registerReceiver(receiver, IntentFilter(ACTION_USB_PERMISSION))
          manager.requestPermission(device, pendingPermissionIntent(context))
        }
      }
      "openDevice" -> {
        val manager = usbManager ?: return result.error("IllegalState", "usbManager null", null)
        val identifier = call.argument<String>("identifier")
        usbDevice = manager.deviceList[identifier]
        usbDeviceConnection = manager.openDevice(usbDevice)
        result.success(true)
      }
      "closeDevice" -> {
        usbDeviceConnection?.close()
        usbDeviceConnection = null
        usbDevice = null
        result.success(null)
      }
      "getConfiguration" -> {
        val device = usbDevice ?: return result.error("IllegalState", "usbDevice null", null)
        val index = call.argument<Int>("index")!!
        val configuration = device.getConfiguration(index)
        val map = configuration.toMap() + ("index" to index)
        result.success(map)
      }
      "setConfiguration" -> {
        val device = usbDevice ?: return result.error("IllegalState", "usbDevice null", null)
        val connection = usbDeviceConnection ?: return result.error("IllegalState", "usbDeviceConnection null", null)
        val index = call.argument<Int>("index")!!
        val configuration = device.getConfiguration(index)
        result.success(connection.setConfiguration(configuration))
      }
      "claimInterface" -> {
        val device = usbDevice ?: return result.error("IllegalState", "usbDevice null", null)
        val connection = usbDeviceConnection ?: return result.error("IllegalState", "usbDeviceConnection null", null)
        val id = call.argument<Int>("id")!!
        val alternateSetting = call.argument<Int>("alternateSetting")!!
        val usbInterface = device.findInterface(id, alternateSetting)
        result.success(connection.claimInterface(usbInterface, true))
      }
      "releaseInterface" -> {
        val device = usbDevice ?: return result.error("IllegalState", "usbDevice null", null)
        val connection = usbDeviceConnection ?: return result.error("IllegalState", "usbDeviceConnection null", null)
        val id = call.argument<Int>("id")!!
        val alternateSetting = call.argument<Int>("alternateSetting")!!
        val usbInterface = device.findInterface(id, alternateSetting)
        result.success(connection.releaseInterface(usbInterface))
      }
      "bulkTransferIn" -> {
        val device = usbDevice ?: return result.error("IllegalState", "usbDevice null", null)
        val connection = usbDeviceConnection ?: return result.error(
          "IllegalState",
          "usbDeviceConnection null",
          null
        )
        val endpointMap = call.argument<Map<String, Any>>("endpoint")!!
        val maxLength = call.argument<Int>("maxLength")!!
        val endpoint =
          device.findEndpoint(endpointMap["endpointNumber"] as Int, endpointMap["direction"] as Int)
        val timeout = call.argument<Int>("timeout")!!

        // TODO Check [UsbDeviceConnection.bulkTransfer] API >= 28
        require(maxLength <= UsbRequest__MAX_USBFS_BUFFER_SIZE) { "Before 28, a value larger than 16384 bytes would be truncated down to 16384" }

        // Off-load the blocking bulkTransfer onto ioExecutor — see the
        // class-level comment about ANR avoidance.
        ioExecutor.execute {
          val buffer = ByteArray(maxLength)
          val actualLength = try {
            connection.bulkTransfer(endpoint, buffer, buffer.count(), timeout)
          } catch (t: Throwable) {
            postError(result, "unknown", "bulkTransferIn exception: ${t.message}")
            return@execute
          }
          if (actualLength < 0) {
            postError(result, "unknown", "bulkTransferIn error")
          } else {
            postSuccess(result, buffer.take(actualLength))
          }
        }
      }
      "bulkTransferOut" -> {
        val device = usbDevice ?: return result.error("IllegalState", "usbDevice null", null)
        val connection = usbDeviceConnection ?: return result.error(
          "IllegalState",
          "usbDeviceConnection null",
          null
        )
        val endpointMap = call.argument<Map<String, Any>>("endpoint")!!
        val data = call.argument<ByteArray>("data")!!
        val timeout = call.argument<Int>("timeout")!!
        val endpoint =
          device.findEndpoint(endpointMap["endpointNumber"] as Int, endpointMap["direction"] as Int)

        // TODO Check [UsbDeviceConnection.bulkTransfer] API >= 28
        val dataSplit = data.asList()
          .windowed(UsbRequest__MAX_USBFS_BUFFER_SIZE, UsbRequest__MAX_USBFS_BUFFER_SIZE, true)
          .map { it.toByteArray() }

        ioExecutor.execute {
          var sum: Int? = null
          try {
            for (bytes in dataSplit) {
              val actualLength = connection.bulkTransfer(endpoint, bytes, bytes.count(), timeout)
              if (actualLength < 0) break
              sum = (sum ?: 0) + actualLength
            }
          } catch (t: Throwable) {
            postError(result, "unknown", "bulkTransferOut exception: ${t.message}")
            return@execute
          }
          if (sum == null) {
            postError(result, "unknown", "bulkTransferOut error")
          } else {
            postSuccess(result, sum)
          }
        }
      }
      "clearHalt" -> {
        // Patched (nikon_z_control fork): CLEAR_FEATURE(ENDPOINT_HALT) via a
        // synchronous control transfer. Needed after we claim the interface
        // to wipe any residual halt on the bulk endpoints left over by a
        // previously crashed session — otherwise the very first
        // bulkTransferOut wedges and eventually ANRs.
        val connection = usbDeviceConnection ?: return result.error(
          "IllegalState",
          "usbDeviceConnection null",
          null
        )
        val endpointMap = call.argument<Map<String, Any>>("endpoint")!!
        val endpointNumber = endpointMap["endpointNumber"] as Int
        val direction = endpointMap["direction"] as Int
        val timeout = call.argument<Int>("timeout") ?: 1000
        val endpointAddress = endpointNumber or direction

        ioExecutor.execute {
          // requestType = 0x02 (standard, host-to-device, recipient=endpoint)
          // request     = 0x01 (CLEAR_FEATURE)
          // value       = 0x00 (ENDPOINT_HALT)
          // index       = endpoint address (number | direction bit)
          val rc = try {
            connection.controlTransfer(0x02, 0x01, 0x00, endpointAddress, null, 0, timeout)
          } catch (t: Throwable) {
            postError(result, "unknown", "clearHalt exception: ${t.message}")
            return@execute
          }
          // Android returns 0 on success for a zero-length control transfer,
          // negative on error. We collapse both into a plain boolean.
          postSuccess(result, rc >= 0)
        }
      }
      else -> result.notImplemented()
    }
  }
}

fun UsbDevice.findInterface(id: Int, alternateSetting: Int): UsbInterface? {
  for (i in 0..interfaceCount) {
    val usbInterface = getInterface(i)
    if (usbInterface.id == id && usbInterface.alternateSetting == alternateSetting) {
      return usbInterface
    }
  }
  return null
}

fun UsbDevice.findEndpoint(endpointNumber: Int, direction: Int): UsbEndpoint? {
  for (i in 0..interfaceCount) {
    val usbInterface = getInterface(i)
    for (j in 0..usbInterface.endpointCount) {
      val endpoint = usbInterface.getEndpoint(j)
      if (endpoint.endpointNumber == endpointNumber && endpoint.direction == direction) {
        return endpoint
      }
    }
  }
  return null
}

/** [UsbRequest.MAX_USBFS_BUFFER_SIZE] */
val UsbRequest__MAX_USBFS_BUFFER_SIZE = 16384

fun UsbConfiguration.toMap() = mapOf(
  "id" to id,
  "interfaces" to List(interfaceCount) { getInterface(it).toMap() }
)

fun UsbInterface.toMap() = mapOf(
  "id" to id,
  "alternateSetting" to alternateSetting,
  "endpoints" to List(endpointCount) { getEndpoint(it).toMap() }
)

fun UsbEndpoint.toMap() = mapOf(
        "endpointNumber" to endpointNumber,
        "direction" to direction
)
