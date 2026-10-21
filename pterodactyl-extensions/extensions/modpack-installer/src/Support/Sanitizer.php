<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

final class Sanitizer
{
    /** Launch scripts a modpack brings that the egg's own startup replaces (FR-MI9). */
    public const SANITIZED_FILES = [
        'start.sh',
        'run.bat',
        'user_jvm_args.txt',
        'start.bat',
        'ServerStart.bat',
    ];

    /**
     * The fixed list plus what the admin added, without the admin's entries that are not plain file names: a name with a
     * path in it could point the delete anywhere in the server (T-MI4, NFR-MI10).
     *
     * @param  list<string>  $extraSanitized
     * @return list<string>
     */
    public static function files(array $extraSanitized): array
    {
        return array_values(array_unique([...self::SANITIZED_FILES, ...array_filter($extraSanitized, self::isFilenameOnly(...))]));
    }

    /** 1 to 64 characters, no separator of either kind, not "." or "..", no control character. */
    public static function isFilenameOnly(string $name): bool
    {
        return strlen($name) >= 1 && strlen($name) <= 64
            && $name !== '.' && $name !== '..'
            && preg_match('/[\/\\\\\x00-\x1f\x7f]/', $name) !== 1;
    }
}
