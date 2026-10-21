<?php

declare(strict_types=1);

namespace MultiNodeSync\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use Illuminate\Support\Facades\Log;
use MultiNodeSync\Support\MultiNodeSyncSettings;
use MultiNodeSync\Support\PathValidator;
use MultiNodeSync\Support\S3PresignedUrl;

class S3Controller extends Controller
{
    public function __construct(
        private MultiNodeSyncSettings $settings,
    ) {}

    public function config(Request $request): JsonResponse
    {
        $s3 = $this->settings->s3Config();

        return response()->json([
            'configured' => $s3->configured(),
            'endpoint' => $s3->endpoint(),
            'region' => $s3->region(),
            'bucket' => $s3->bucket(),
        ]);
    }

    public function presign(Request $request): JsonResponse
    {
        $s3 = $this->settings->s3Config();

        if (! $s3->configured()) {
            return response()->json(['error' => 's3_not_configured'], 503);
        }

        $input = $request->validate([
            'method' => ['required', 'string', 'in:GET,PUT'],
            'object_key' => ['required', 'string', 'max:1024'],
        ]);

        $pathError = PathValidator::validate($input['object_key'], 1024);
        if ($pathError !== null) {
            return response()->json(['error' => $pathError], 422);
        }

        $expiresMinutes = $this->settings->presignedTtlMinutes();
        $presignedUrl = new S3PresignedUrl($s3);

        try {
            $result = $presignedUrl->generate($input['method'], $input['object_key'], $expiresMinutes);
        } catch (\RuntimeException $e) {
            return response()->json(['error' => $e->getMessage()], 503);
        }

        Log::info('multi-node-sync: presigned URL generated', [
            'object_key' => $result->objectKey,
            'method' => $result->method,
            'expires_at' => $result->expiresAt,
        ]);

        return response()->json([
            'url' => $result->url,
            'method' => $result->method,
            'expires_at' => $result->expiresAt,
            'object_key' => $result->objectKey,
        ]);
    }
}
