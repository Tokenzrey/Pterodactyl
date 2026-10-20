<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('ext_oauth_login_identities', function (Blueprint $table): void {
            $table->id();
            $table->unsignedInteger('user_id');
            $table->string('provider', 20);
            // Compared byte for byte: a provider id is an opaque identifier, not text.
            $table->string('provider_user_id', 255)->collation('utf8mb4_bin');
            $table->timestamp('created_at')->useCurrent();

            // One account per provider identity, and one identity per provider per user.
            $table->unique(['provider', 'provider_user_id']);
            $table->unique(['user_id', 'provider']);
            $table->foreign('user_id')->references('id')->on('users')->cascadeOnDelete();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('ext_oauth_login_identities');
    }
};
