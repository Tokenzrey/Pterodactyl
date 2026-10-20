<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('ext_subdomain_manager_records', function (Blueprint $table): void {
            $table->id();
            // No foreign key on purpose: the row has to outlive the server until its DNS records are gone.
            $table->unsignedInteger('server_id')->nullable();
            $table->char('server_uuid', 36)->unique();
            $table->string('domain', 253);
            $table->string('label', 63);
            // The zone the records below live in, kept so they can be deleted after the domain list changes.
            $table->char('zone_id', 32);
            $table->string('synced_name', 253)->nullable();
            $table->string('a_record_id', 64)->nullable();
            $table->string('srv_record_id', 64)->nullable();
            $table->string('status', 16);
            $table->string('last_error', 255)->nullable();
            $table->unsignedTinyInteger('attempts')->default(0);
            $table->timestamps();

            // One server per name. Two admins saving the same name at once: the loser gets a validation error.
            $table->unique(['domain', 'label']);
            $table->index('status');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('ext_subdomain_manager_records');
    }
};
