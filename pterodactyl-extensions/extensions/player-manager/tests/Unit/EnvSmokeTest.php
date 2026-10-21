<?php

declare(strict_types=1);

// Smoke: the runner finds this suite and the PSR-4 map of the extension resolves.
test('extension classes autoload without booting the provider', function (): void {
    expect(class_exists(PlayerManager\PlayerManagerProvider::class))->toBeTrue();
});
