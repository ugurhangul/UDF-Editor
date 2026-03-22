package com.udftor.udf_editor

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.hardware.usb.*
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Handles USB OTG smart card reader communication via CCID protocol.
 *
 * This handler provides three MethodChannel methods:
 * - `isAvailable`: Check if USB host mode is supported and a reader is connected
 * - `connect`: Open connection to first detected CCID reader
 * - `disconnect`: Close USB connection
 * - `transceive`: Send hex-encoded APDU and receive hex-encoded response
 *
 * CCID (Chip Card Interface Device) is the USB protocol for smart card readers.
 * We use USB bulk transfers to send/receive CCID frames wrapping APDU commands.
 */
class UsbOtgChannelHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    private var usbManager: UsbManager? = null
    private var usbConnection: UsbDeviceConnection? = null
    private var usbInterface: UsbInterface? = null
    private var endpointIn: UsbEndpoint? = null
    private var endpointOut: UsbEndpoint? = null
    private var sequenceNumber: Byte = 0

    companion object {
        // CCID class code
        private const val USB_CLASS_CCID = 0x0B

        // CCID message types
        private const val PC_TO_RDR_XFRBLOCK: Byte = 0x6F
        private const val RDR_TO_PC_DATABLOCK: Byte = 0x80.toByte()

        // Timeout for USB transfers (ms)
        private const val USB_TIMEOUT = 5000

        private const val ACTION_USB_PERMISSION = "com.udftor.udf_editor.USB_PERMISSION"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            "connect" -> connect(result)
            "disconnect" -> {
                disconnect()
                result.success(true)
            }
            "transceive" -> {
                val apduHex = call.argument<String>("apdu")
                if (apduHex == null) {
                    result.error("INVALID_ARGUMENT", "APDU hex string required", null)
                    return
                }
                transceive(apduHex, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun isAvailable(): Boolean {
        val manager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return false
        usbManager = manager
        return findCcidDevice(manager) != null
    }

    private fun connect(result: MethodChannel.Result) {
        val manager = context.getSystemService(Context.USB_SERVICE) as? UsbManager
        if (manager == null) {
            result.success(false)
            return
        }
        usbManager = manager

        val device = findCcidDevice(manager)
        if (device == null) {
            result.success(false)
            return
        }

        // Check permission
        if (!manager.hasPermission(device)) {
            val permissionIntent = PendingIntent.getBroadcast(
                context, 0,
                Intent(ACTION_USB_PERMISSION),
                PendingIntent.FLAG_IMMUTABLE
            )
            manager.requestPermission(device, permissionIntent)
            // For simplicity, return false — user needs to retry after granting permission
            result.success(false)
            return
        }

        // Open connection
        val connection = manager.openDevice(device) ?: run {
            result.success(false)
            return
        }

        // Find CCID interface and endpoints
        val iface = findCcidInterface(device) ?: run {
            connection.close()
            result.success(false)
            return
        }

        if (!connection.claimInterface(iface, true)) {
            connection.close()
            result.success(false)
            return
        }

        // Find bulk IN and OUT endpoints
        var bulkIn: UsbEndpoint? = null
        var bulkOut: UsbEndpoint? = null
        for (i in 0 until iface.endpointCount) {
            val ep = iface.getEndpoint(i)
            if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                if (ep.direction == UsbConstants.USB_DIR_IN) {
                    bulkIn = ep
                } else {
                    bulkOut = ep
                }
            }
        }

        if (bulkIn == null || bulkOut == null) {
            connection.releaseInterface(iface)
            connection.close()
            result.success(false)
            return
        }

        usbConnection = connection
        usbInterface = iface
        endpointIn = bulkIn
        endpointOut = bulkOut
        sequenceNumber = 0

        // Send ICC Power On to activate the card
        val powerOnResult = sendCcidPowerOn(connection, bulkOut, bulkIn)
        result.success(powerOnResult)
    }

    private fun disconnect() {
        usbConnection?.let { conn ->
            usbInterface?.let { iface ->
                conn.releaseInterface(iface)
            }
            conn.close()
        }
        usbConnection = null
        usbInterface = null
        endpointIn = null
        endpointOut = null
    }

    private fun transceive(apduHex: String, result: MethodChannel.Result) {
        val conn = usbConnection
        val epOut = endpointOut
        val epIn = endpointIn

        if (conn == null || epOut == null || epIn == null) {
            result.error("NOT_CONNECTED", "USB connection not established", null)
            return
        }

        try {
            val apduBytes = hexToBytes(apduHex)
            val responseBytes = sendCcidXfrBlock(conn, epOut, epIn, apduBytes)
            if (responseBytes != null) {
                result.success(bytesToHex(responseBytes))
            } else {
                result.error("TRANSCEIVE_FAILED", "No response from card", null)
            }
        } catch (e: Exception) {
            result.error("TRANSCEIVE_ERROR", e.message, null)
        }
    }

    // ── CCID protocol ───────────────────────────────────────────────

    /**
     * Send PC_to_RDR_IccPowerOn to activate the smart card.
     */
    private fun sendCcidPowerOn(
        conn: UsbDeviceConnection,
        epOut: UsbEndpoint,
        epIn: UsbEndpoint
    ): Boolean {
        val header = ByteArray(10)
        header[0] = 0x62 // PC_to_RDR_IccPowerOn
        // dwLength = 0 (no data)
        header[5] = 0 // bSlot
        header[6] = sequenceNumber++
        header[7] = 0 // bPowerSelect: auto

        val sent = conn.bulkTransfer(epOut, header, header.size, USB_TIMEOUT)
        if (sent < 0) return false

        // Read ATR response
        val response = ByteArray(512)
        val received = conn.bulkTransfer(epIn, response, response.size, USB_TIMEOUT)
        return received >= 10 && response[0] == RDR_TO_PC_DATABLOCK
    }

    /**
     * Send PC_to_RDR_XfrBlock wrapping an APDU command.
     * Returns the APDU response bytes (without CCID framing).
     */
    private fun sendCcidXfrBlock(
        conn: UsbDeviceConnection,
        epOut: UsbEndpoint,
        epIn: UsbEndpoint,
        apdu: ByteArray
    ): ByteArray? {
        // Build CCID frame
        val frame = ByteArray(10 + apdu.size)
        frame[0] = PC_TO_RDR_XFRBLOCK
        // dwLength (little-endian)
        frame[1] = (apdu.size and 0xFF).toByte()
        frame[2] = ((apdu.size shr 8) and 0xFF).toByte()
        frame[3] = ((apdu.size shr 16) and 0xFF).toByte()
        frame[4] = ((apdu.size shr 24) and 0xFF).toByte()
        frame[5] = 0 // bSlot
        frame[6] = sequenceNumber++
        frame[7] = 0 // bBWI
        // wLevelParameter = 0
        System.arraycopy(apdu, 0, frame, 10, apdu.size)

        val sent = conn.bulkTransfer(epOut, frame, frame.size, USB_TIMEOUT)
        if (sent < 0) return null

        // Read response
        val response = ByteArray(65546) // Max CCID response
        val received = conn.bulkTransfer(epIn, response, response.size, USB_TIMEOUT)
        if (received < 10) return null
        if (response[0] != RDR_TO_PC_DATABLOCK) return null

        // Extract data length
        val dwLength = (response[1].toInt() and 0xFF) or
                ((response[2].toInt() and 0xFF) shl 8) or
                ((response[3].toInt() and 0xFF) shl 16) or
                ((response[4].toInt() and 0xFF) shl 24)

        if (dwLength <= 0 || dwLength > received - 10) return null

        return response.copyOfRange(10, 10 + dwLength)
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private fun findCcidDevice(manager: UsbManager): UsbDevice? {
        for ((_, device) in manager.deviceList) {
            for (i in 0 until device.interfaceCount) {
                if (device.getInterface(i).interfaceClass == USB_CLASS_CCID) {
                    return device
                }
            }
        }
        return null
    }

    private fun findCcidInterface(device: UsbDevice): UsbInterface? {
        for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            if (iface.interfaceClass == USB_CLASS_CCID) {
                return iface
            }
        }
        return null
    }

    private fun hexToBytes(hex: String): ByteArray {
        val len = hex.length / 2
        val bytes = ByteArray(len)
        for (i in 0 until len) {
            bytes[i] = hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
        return bytes
    }

    private fun bytesToHex(bytes: ByteArray): String {
        return bytes.joinToString("") { "%02X".format(it) }
    }
}
