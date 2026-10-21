<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('ext_modpack_installer_jobs', function (Blueprint $table): void {
            $table->id();
            $table->char('server_uuid', 36);
            $table->string('source', 16);
            $table->string('project_id', 64);
            $table->string('file_id', 64);
            $table->string('target_directory', 255);
            $table->char('job_id', 36)->nullable();
            $table->string('status', 16)->default('pending');
            $table->string('last_error', 255)->nullable();
            $table->timestamps();

            // Not unique: the same pack may be installed again once an install has finished. "Is one already running"
            // is answered by the status, and by how recently the row was touched.
            $table->index(['server_uuid', 'project_id', 'file_id']);
            $table->index('job_id');
            $table->index('status');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('ext_modpack_installer_jobs');
    }
};
