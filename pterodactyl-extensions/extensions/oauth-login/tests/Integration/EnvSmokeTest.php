<?php

declare(strict_types=1);

use Illuminate\Support\Facades\DB;
use Pterodactyl\Tests\Integration\IntegrationTestCase;

uses(IntegrationTestCase::class);

// Smoke: integration tests hit the throw-away test database, never anything else.
test('integration tests run against the throw-away test database', function (): void {
    expect(DB::connection()->getDatabaseName())->toContain('test');
});
