package cicada

import java.math.BigInteger
import java.security.MessageDigest

/// Ed25519 signing (RFC 8032), for the share service's device key (ShareClient). Android has it
/// built in only from Android 13 (API 33) and the app runs from Android 10, so this is the RFC's
/// reference algorithm on BigInteger, with the platform's SHA-512: slow by crypto standards (tens
/// of milliseconds a signature), which is nothing for one request. Signing only; the server
/// verifies. Tested against RFC 8032's vectors and the JDK's own Ed25519 (cli Tests).
/// Not constant-time: the key only names this phone to the share service (rate limits and owning
/// its links), and nothing else on the phone can time the signing.
object Ed25519 {
    private val TWO = BigInteger.valueOf(2) // BigInteger.TWO is Android 13+
    private val P = BigInteger.ONE.shiftLeft(255).subtract(BigInteger.valueOf(19))
    private val Q = BigInteger.ONE.shiftLeft(252).add(BigInteger("27742317777372353535851937790883648493"))
    private val D = BigInteger.valueOf(-121665).multiply(inv(BigInteger.valueOf(121666))).mod(P)
    private val D2 = D.shiftLeft(1).mod(P)
    private val SQRT_M1 = TWO.modPow(P.subtract(BigInteger.ONE).shiftRight(2), P)
    private val G: Array<BigInteger> = run {
        val y = BigInteger.valueOf(4).multiply(inv(BigInteger.valueOf(5))).mod(P)
        val x = recoverX(y)
        arrayOf(x, y, BigInteger.ONE, x.multiply(y).mod(P))
    }

    private fun inv(x: BigInteger) = x.modPow(P.subtract(TWO), P)

    private fun recoverX(y: BigInteger): BigInteger {
        val yy = y.multiply(y)
        val x2 = yy.subtract(BigInteger.ONE).multiply(inv(D.multiply(yy).add(BigInteger.ONE))).mod(P)
        var x = x2.modPow(P.add(BigInteger.valueOf(3)).shiftRight(3), P)
        if (x.multiply(x).subtract(x2).mod(P).signum() != 0) x = x.multiply(SQRT_M1).mod(P)
        return if (x.testBit(0)) P.subtract(x) else x // the base point's x is even
    }

    // Extended coordinates (X, Y, Z, T), x = X/Z, y = Y/Z, xy = T/Z.
    private fun add(a: Array<BigInteger>, b: Array<BigInteger>): Array<BigInteger> {
        val pa = a[1].subtract(a[0]).multiply(b[1].subtract(b[0])).mod(P)
        val pb = a[1].add(a[0]).multiply(b[1].add(b[0])).mod(P)
        val c = a[3].multiply(D2).multiply(b[3]).mod(P)
        val d = a[2].shiftLeft(1).multiply(b[2]).mod(P)
        val e = pb.subtract(pa); val f = d.subtract(c); val g = d.add(c); val h = pb.add(pa)
        return arrayOf(e.multiply(f).mod(P), g.multiply(h).mod(P), f.multiply(g).mod(P), e.multiply(h).mod(P))
    }

    private fun mul(scalar: BigInteger, point: Array<BigInteger>): Array<BigInteger> {
        var q = arrayOf(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO)
        var p = point
        for (i in 0 until scalar.bitLength()) {
            if (scalar.testBit(i)) q = add(q, p)
            p = add(p, p)
        }
        return q
    }

    private fun compress(pt: Array<BigInteger>): ByteArray {
        val z = inv(pt[2])
        val x = pt[0].multiply(z).mod(P)
        var y = pt[1].multiply(z).mod(P)
        if (x.testBit(0)) y = y.setBit(255)
        return little(y)
    }

    private fun little(n: BigInteger): ByteArray {
        val big = n.toByteArray()
        val out = ByteArray(32)
        for (i in 0 until minOf(32, big.size)) out[i] = big[big.size - 1 - i]
        return out
    }

    private fun number(b: ByteArray): BigInteger = BigInteger(1, b.reversedArray())

    private fun sha512(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-512")
        for (p in parts) md.update(p)
        return md.digest()
    }

    private fun expand(seed: ByteArray): Pair<BigInteger, ByteArray> {
        require(seed.size == 32) { "an Ed25519 seed is 32 bytes" }
        val h = sha512(seed)
        val a = number(h.copyOfRange(0, 32)).and(BigInteger.ONE.shiftLeft(254).subtract(BigInteger.valueOf(8))).setBit(254)
        return a to h.copyOfRange(32, 64)
    }

    /// The 32-byte public key of a 32-byte private seed.
    fun publicKey(seed: ByteArray): ByteArray = compress(mul(expand(seed).first, G))

    /// A 64-byte signature of `message`.
    fun sign(seed: ByteArray, message: ByteArray, publicKey: ByteArray = publicKey(seed)): ByteArray {
        val (a, prefix) = expand(seed)
        val r = number(sha512(prefix, message)).mod(Q)
        val rs = compress(mul(r, G))
        val h = number(sha512(rs, publicKey, message)).mod(Q)
        val s = r.add(h.multiply(a)).mod(Q)
        return rs + little(s)
    }
}
