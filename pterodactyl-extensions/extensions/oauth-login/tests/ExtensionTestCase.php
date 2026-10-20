<?php

declare(strict_types=1);

namespace OauthLogin\Tests;

use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Http\Client\Factory as HttpFactory;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Facades\Http;
use Illuminate\Testing\TestResponse;
use Pterodactyl\Models\Extension;
use Pterodactyl\Services\Extensions\ExtensionProviderLoader;
use Pterodactyl\Services\Extensions\ExtensionRepository;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use Pterodactyl\Tests\Integration\IntegrationTestCase;

/**
 * Boots the Panel with the oauth-login extension installed and enabled from its source directory,
 * exactly as the loader would, so routes, settings and the provider are the real ones.
 */
abstract class ExtensionTestCase extends IntegrationTestCase
{
    use DatabaseTransactions;

    private string $assets;

    protected function setUp(): void
    {
        parent::setUp();

        $this->assets = sys_get_temp_dir().'/oauth-login-assets-'.uniqid();
        config([
            'extensions.enabled' => true,
            'extensions.directory' => '/ext-src',
            'extensions.assets_directory' => $this->assets,
            'app.url' => 'https://panel.test',
        ]);
        $this->app->forgetInstance(ExtensionRepository::class);
        $this->app->forgetInstance(ExtensionProviderLoader::class);

        Extension::query()->create(['identifier' => 'oauth-login', 'version' => '1.0.0', 'enabled' => true]);
        $repository = $this->app->make(ExtensionRepository::class);
        $repository->flushDiscovery();
        $this->app->make(ExtensionProviderLoader::class)->registerProviders($repository->enabled());

        // The Panel records a failed boot on the extension row and carries on; a test must not.
        $error = Extension::query()->where('identifier', 'oauth-login')->value('error');
        if ($error !== null) {
            throw new RuntimeException("oauth-login failed to load: $error");
        }
    }

    protected function tearDown(): void
    {
        $this->app->make(ExtensionRepository::class)->flushDiscovery();
        File::deleteDirectory($this->assets);

        parent::tearDown();
    }

    /** Saves settings the way the admin form does (secrets are encrypted at rest). @param array<string, mixed> $values */
    protected function configure(array $values): void
    {
        $this->app->make(ExtensionSettingsRegistry::class)->get('oauth-login')->update($values);
    }

    protected function enableProvider(string $provider = 'discord', array $more = []): void
    {
        $this->configure([
            'enabled_providers' => [$provider],
            $provider.'_client_id' => 'client-id-'.$provider,
            $provider.'_client_secret' => 'S3CRET-'.$provider,
            ...$more,
        ]);
    }

    /** Opens a flow the way the browser does and returns the state the provider would echo back. */
    protected function beginFlow(string $provider = 'discord'): string
    {
        $location = $this->get("/extensions/oauth-login/redirect/$provider")->assertStatus(302)->headers->get('Location');
        parse_str((string) parse_url($location, PHP_URL_QUERY), $query);

        return $query['state'];
    }

    /** The provider sends the browser back: GET callback with the given query. @param array<string, mixed> $query */
    protected function returnFromProvider(string $provider, array $query): TestResponse
    {
        return $this->get("/extensions/oauth-login/callback/$provider?".http_build_query($query));
    }

    /** A complete, valid round trip up to the callback; `$query` overrides or adds callback parameters. */
    protected function signIn(string $provider = 'discord', array $query = []): TestResponse
    {
        return $this->returnFromProvider($provider, ['code' => 'AUTH-CODE-123', 'state' => $this->beginFlow($provider), ...$query]);
    }

    /**
     * Replaces the HTTP client and fakes exactly these routes. Http::fake() alone would add to the
     * stubs already registered, and the first matching stub wins, so a later fake could never override.
     *
     * @param array<string, mixed> $routes
     */
    protected function fakeHttp(array $routes): void
    {
        Http::swap(new HttpFactory);
        Http::preventStrayRequests();
        Http::fake($routes);
    }

    /** @param array<string, mixed> $me */
    protected function fakeDiscord(array $me = []): void
    {
        $this->fakeHttp([
            'https://discord.com/api/oauth2/token' => Http::response(['access_token' => 'TOKEN-discord', 'token_type' => 'Bearer']),
            'https://discord.com/api/users/@me' => Http::response($me + ['id' => '80351110224678912', 'username' => 'nelly', 'global_name' => 'Nelly Furtado', 'verified' => true, 'email' => 'nelly@discord.test']),
        ]);
    }

    /** @param array<string, mixed> $user @param list<array<string, mixed>>|null $emails */
    protected function fakeGithub(array $user = [], ?array $emails = null): void
    {
        $this->fakeHttp([
            'https://github.com/login/oauth/access_token' => Http::response(['access_token' => 'TOKEN-github', 'token_type' => 'bearer']),
            'https://api.github.com/user' => Http::response($user + ['login' => 'octocat', 'id' => 583231, 'name' => 'The Octocat']),
            'https://api.github.com/user/emails' => Http::response($emails ?? [['email' => 'octocat@github.test', 'primary' => true, 'verified' => true]]),
        ]);
    }

    /** @param array<string, mixed> $info */
    protected function fakeGoogle(array $info = []): void
    {
        $this->fakeHttp([
            'https://oauth2.googleapis.com/token' => Http::response(['access_token' => 'TOKEN-google', 'token_type' => 'Bearer']),
            'https://openidconnect.googleapis.com/v1/userinfo' => Http::response($info + ['sub' => '110248495921238986420', 'name' => 'Ada Lovelace', 'email' => 'ada@google.test', 'email_verified' => true]),
        ]);
    }
}
