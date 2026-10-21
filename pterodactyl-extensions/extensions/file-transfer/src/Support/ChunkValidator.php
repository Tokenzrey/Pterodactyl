<?php

declare(strict_types=1);

namespace FileTransfer\Support;

/**
 * The shape of one chunk's request: who it belongs to, where it sits in the file, and the name it will have. All
 * patterns end with \z, not $: in PCRE `$` also matches before a final newline, so "a.zip\n" would pass.
 */
final class ChunkValidator
{
    public const MAX_TOTAL_CHUNKS = 10000;

    private const MAX_FILENAME_LENGTH = 255;

    /** A version 4 UUID: what the browser makes with crypto.randomUUID(). */
    private const UUID_V4 = '/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i';

    private const FILENAME = '/\A[a-zA-Z0-9_\-.]+\z/';

    private const SHA256 = '/\A[0-9a-f]{64}\z/i';

    public static function validate(string $uploadId, int $index, int $totalChunks, string $filename, string $checksum): ?string
    {
        if (! self::validUploadId($uploadId)) {
            return 'invalid_upload_id';
        }

        // The total comes first: with 0 chunks every index is out of range, and the real problem is the total.
        if ($totalChunks < 1 || $totalChunks > self::MAX_TOTAL_CHUNKS) {
            return 'invalid_total_chunks';
        }

        if ($index < 0 || $index >= $totalChunks) {
            return 'invalid_chunk_index';
        }

        if (! self::validateFilename($filename)) {
            return 'invalid_filename';
        }

        if (! self::validChecksum($checksum)) {
            return 'invalid_checksum';
        }

        return null;
    }

    public static function validUploadId(string $uploadId): bool
    {
        return preg_match(self::UUID_V4, $uploadId) === 1;
    }

    public static function validChecksum(string $checksum): bool
    {
        return preg_match(self::SHA256, $checksum) === 1;
    }

    /** 1 to 255 letters, digits, "_", "-" and ".", and not made of dots alone: "." and ".." would name a directory. */
    public static function validateFilename(string $name): bool
    {
        return $name !== ''
            && strlen($name) <= self::MAX_FILENAME_LENGTH
            && trim($name, '.') !== ''
            && preg_match(self::FILENAME, $name) === 1;
    }
}
