using System.Numerics;
using System.Security.Cryptography;

namespace Cicada;

/// Ed25519 signatures (RFC 8032 §5.1), for the share service's device key. .NET 10 has no Ed25519
/// of its own (only inside composite ML-DSA) and Windows CNG can't sign with it, so this is the
/// RFC's reference algorithm over BigInteger with the built-in SHA-512, checked against the RFC's
/// test vectors. Not constant-time: the key only names this install to the share service (rate
/// limits, owning its shares), and anyone can make a new one, so a local timing attack gains nothing.
public static class Ed25519
{
    static readonly BigInteger P = BigInteger.Pow(2, 255) - 19;
    static readonly BigInteger L = BigInteger.Pow(2, 252) + BigInteger.Parse("27742317777372353535851937790883648493");
    static readonly BigInteger D = Mod(-121665 * Inv(121666));
    static readonly BigInteger SqrtM1 = BigInteger.ModPow(2, (P - 1) / 4, P);
    static readonly Point G = Base();

    readonly record struct Point(BigInteger X, BigInteger Y, BigInteger Z, BigInteger T);

    static BigInteger Mod(BigInteger x) { var r = x % P; return r.Sign < 0 ? r + P : r; }
    static BigInteger Inv(BigInteger x) => BigInteger.ModPow(x, P - 2, P);

    static Point Base()
    {
        var y = Mod(4 * Inv(5));
        var x = RecoverX(y, 0)!.Value;
        return new(x, y, 1, Mod(x * y));
    }

    static Point Add(Point p, Point q)
    {
        var a = Mod((p.Y - p.X) * (q.Y - q.X));
        var b = Mod((p.Y + p.X) * (q.Y + q.X));
        var c = Mod(2 * p.T * q.T * D);
        var d = Mod(2 * p.Z * q.Z);
        BigInteger e = b - a, f = d - c, g = d + c, h = b + a;
        return new(Mod(e * f), Mod(g * h), Mod(f * g), Mod(e * h));
    }

    static Point Multiply(BigInteger s, Point p)
    {
        var q = new Point(0, 1, 1, 0);
        while (s > 0)
        {
            if (!s.IsEven) q = Add(q, p);
            p = Add(p, p);
            s >>= 1;
        }
        return q;
    }

    static bool Same(Point p, Point q) =>
        Mod(p.X * q.Z - q.X * p.Z) == 0 && Mod(p.Y * q.Z - q.Y * p.Z) == 0;

    static BigInteger? RecoverX(BigInteger y, int sign)
    {
        if (y >= P) return null;
        var x2 = Mod((y * y - 1) * Inv(D * y * y + 1));
        if (x2 == 0) return sign == 1 ? null : 0;
        var x = BigInteger.ModPow(x2, (P + 3) / 8, P);
        if (Mod(x * x - x2) != 0) x = Mod(x * SqrtM1);
        if (Mod(x * x - x2) != 0) return null;
        if ((int)(x & 1) != sign) x = P - x;
        return x;
    }

    static byte[] Compress(Point p)
    {
        var zi = Inv(p.Z);
        var x = Mod(p.X * zi);
        var y = Mod(p.Y * zi);
        var b = Bytes(y);
        b[31] |= (byte)((int)(x & 1) << 7);
        return b;
    }

    static Point? Decompress(ReadOnlySpan<byte> s)
    {
        if (s.Length != 32) return null;
        var copy = s.ToArray();
        int sign = copy[31] >> 7;
        copy[31] &= 0x7F;
        var y = Number(copy);
        if (RecoverX(y, sign) is not { } x) return null;
        return new(x, y, 1, Mod(x * y));
    }

    static BigInteger Number(ReadOnlySpan<byte> le) => new(le, isUnsigned: true, isBigEndian: false);

    static byte[] Bytes(BigInteger n)
    {
        var raw = n.ToByteArray(isUnsigned: true, isBigEndian: false);
        var b = new byte[32];
        raw.AsSpan(0, Math.Min(32, raw.Length)).CopyTo(b);
        return b;
    }

    static (BigInteger a, byte[] prefix) Expand(ReadOnlySpan<byte> seed)
    {
        if (seed.Length != 32) throw new ArgumentException("an Ed25519 private key is 32 bytes");
        var h = SHA512.HashData(seed);
        h[0] &= 248; h[31] &= 127; h[31] |= 64;
        return (Number(h.AsSpan(0, 32)), h[32..]);
    }

    static BigInteger Hash(params byte[][] parts)
    {
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA512);
        foreach (var p in parts) sha.AppendData(p);
        return Number(sha.GetHashAndReset()) % L;
    }

    /// A new private key (the 32-byte seed RFC 8032 calls the secret key).
    public static byte[] NewKey() => RandomNumberGenerator.GetBytes(32);

    public static byte[] PublicKey(ReadOnlySpan<byte> seed) => Compress(Multiply(Expand(seed).a, G));

    public static byte[] Sign(ReadOnlySpan<byte> seed, byte[] message)
    {
        var (a, prefix) = Expand(seed);
        var pub = Compress(Multiply(a, G));
        var r = Hash(prefix, message);
        var rs = Compress(Multiply(r, G));
        var s = (r + Hash(rs, pub, message) * a) % L;
        return [.. rs, .. Bytes(s)];
    }

    public static bool Verify(ReadOnlySpan<byte> publicKey, byte[] message, ReadOnlySpan<byte> signature)
    {
        if (signature.Length != 64 || Decompress(publicKey) is not { } a || Decompress(signature[..32]) is not { } r) return false;
        var s = Number(signature[32..]);
        if (s >= L) return false;
        var h = Hash(signature[..32].ToArray(), publicKey.ToArray(), message);
        return Same(Multiply(s, G), Add(r, Multiply(h, a)));
    }
}
