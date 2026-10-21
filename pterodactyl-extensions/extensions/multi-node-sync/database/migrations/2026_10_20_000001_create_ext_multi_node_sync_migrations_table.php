<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('ext_multi_node_sync_migrations', function (Blueprint $table): void {
            $table->id();
            $table->unsignedInteger('source_server_id');
            $table->char('source_server_uuid', 36);
            $table->unsignedInteger('target_node_id');
            $table->unsignedInteger('target_allocation_id');
            $table->string('target_directory', 255)->nullable();
            $table->string('status', 16)->default('pending');
            $table->unsignedTinyInteger('progress')->default(0);
            $table->string('job_id', 36)->nullable();
            $table->text('last_error')->nullable();
            $table->timestamps();

            $table->index('source_server_id');
            $table->index('status');
            $table->index('created_at');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('ext_multi_node_sync_migrations');
    }
};
