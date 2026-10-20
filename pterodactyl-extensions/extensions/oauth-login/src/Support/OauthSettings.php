<?php

declare(strict_types=1);

namespace OauthLogin\Support;

use Pterodactyl\Services\Extensions\ExtensionSettingDefinition as Setting;
use Pterodactyl\Services\Extensions\ExtensionSettings;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use RuntimeException;

/**
 * Typed access to the extension's settings (Panel stores client secrets encrypted) and the
 * definition the admin form is rendered from. `enabled_providers` is the only value guests can
 * read; secrets never reach a frontend or an API response.
 */
final readonly class OauthSettings
{
    public const ID = 'oauth-login';

    public function __construct(private ExtensionSettingsDefinition $definition) {}

    public static function fromRegistry(ExtensionSettingsRegistry $registry): self
    {
        return new self($registry->get(self::ID) ?? throw new RuntimeException('The oauth-login settings are not registered.'));
    }

    public static function define(ExtensionSettings $settings): ExtensionSettingsDefinition
    {
        $providers = array_map(fn (Provider $p): array => ['value' => $p->value, 'label' => $p->label()], Provider::cases());

        $fields = [
            Setting::make('enabled_providers', 'enabled_providers', [])
                ->multiselect($providers)->frontend()->public()->tab('General')
                ->label('Enabled providers')
                ->help('Providers shown on the login page. A provider also needs its client ID and secret on its own tab.'),
            Setting::make('allow_registration', 'allow_registration', false)
                ->field('toggle')->tab('General')
                ->label('Create accounts on first sign-in')
                ->help('Off: only users that already exist (matched by verified email) can sign in with a provider.'),
            Setting::make('allow_admin_login', 'allow_admin_login', false)
                ->field('toggle')->tab('General')
                ->label('Allow administrators')
                ->help('Off (recommended): administrator accounts cannot sign in through a provider.'),
            Setting::make('two_factor_policy', 'two_factor_policy', 'block')
                ->field('select', [
                    ['value' => 'block', 'label' => 'Refuse users that have two-factor authentication'],
                    ['value' => Policy::TRUST_PROVIDER, 'label' => 'Trust the provider and skip the Panel two-factor prompt'],
                ])->tab('General')
                ->label('Accounts with two-factor authentication')
                ->help('"Trust the provider" lets a provider account sign in without the TOTP code. Only choose it when you accept that.'),
        ];

        foreach (Provider::cases() as $provider) {
            $fields[] = Setting::make($provider->value.'_client_id', $provider->value.'_client_id', '', ['nullable', 'string', 'max:255', 'regex:/^[A-Za-z0-9._~-]*$/'])
                ->tab($provider->label())->label($provider->label().' client ID')
                ->help('Redirect URI to register at '.$provider->label().': '.RedirectUri::for($provider));
            $fields[] = Setting::make($provider->value.'_client_secret', $provider->value.'_client_secret', '', ['nullable', 'string', 'max:512', 'regex:/^[\x21-\x7E]*$/'])
                ->secret()->tab($provider->label())->label($provider->label().' client secret');
        }

        return new ExtensionSettingsDefinition($settings, $fields);
    }

    /** Listed in `enabled_providers` and has both a client ID and a client secret. */
    public function enabled(Provider $provider): bool
    {
        return in_array($provider->value, (array) $this->definition->get('enabled_providers'), true) && $this->credentials($provider) !== null;
    }

    /** @return array{id: string, secret: string}|null null when either half is missing (EC-O10) */
    public function credentials(Provider $provider): ?array
    {
        $id = $this->definition->get($provider->value.'_client_id');
        $secret = $this->definition->get($provider->value.'_client_secret');

        return is_string($id) && trim($id) !== '' && is_string($secret) && $secret !== ''
            ? ['id' => trim($id), 'secret' => $secret]
            : null;
    }

    public function allowRegistration(): bool
    {
        return $this->definition->get('allow_registration') === true;
    }

    public function allowAdminLogin(): bool
    {
        return $this->definition->get('allow_admin_login') === true;
    }

    public function twoFactorPolicy(): string
    {
        $policy = $this->definition->get('two_factor_policy');

        return is_string($policy) ? $policy : 'block';
    }
}
