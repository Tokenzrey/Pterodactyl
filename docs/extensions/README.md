# Extension Pterodactyl: referensi lengkap, dalam bahasa Indonesia

> **Jenis:** Indeks · **Per:** 2026-10-20 · **Sumber:** [docs.pterodactyl.io/v2/extensions](https://docs.pterodactyl.io/v2/extensions) dan kode Panel tag `v2.0.0-beta.2`

Folder ini menerjemahkan dan merangkum dokumentasi extension resmi Pterodactyl 2.0, lalu mencocokkannya dengan kode Panel yang dikunci repositori ini. Teks upstream berbahasa Inggris dan memakai istilah teknis yang sama dengan kode; istilah itu dipertahankan. Bagian yang kami tambahkan sendiri ditandai **(kode)**.

## Ringkasan

Dokumen upstream tidak sepenuhnya cocok dengan Panel beta.2 yang kami pakai. Tiga temuan yang paling penting:

- **Penggantian komponen** (`ui.components`, `components.replace`) didokumentasikan tetapi **belum ada** di beta.2. Jangan merancang extension yang bergantung padanya.
- **Model tema** di panduan Themes upstream (folder `themes/`, `p:theme:apply`) **bukan** model beta.2. Di beta.2, tema adalah extension dengan `type: theme`, dan repositori ini sudah memakai model itu.
- **Kode beta.2 mengenal lebih banyak** daripada dokumen: sepuluh tipe setting (bukan lima), ID `classic` yang dicadangkan, opsi `make --theme`, `install --replace`, dan pemasangan dari URL bertanda tangan yang aktif secara bawaan.

Paket yang sudah dipasang repositori ini (`announcements`, `custom-buttons`, `unix`) cocok dengan hash di `extensions.lock` dan manifest-nya sesuai dengan kode beta.2. Rincian ada di [kompatibilitas](kompatibilitas.md).

## Urutan membaca

| Langkah | Halaman | Untuk apa |
|---|---|---|
| 1 | [Mengelola](mengelola.md) | pasang, aktifkan, perbarui, dan hapus extension |
| 2 | [Membangun](membangun.md) | kerangka paket, ID, manifest, ikon, dan kompatibilitas |
| 3 | [Backend](backend.md) | provider, rute, otorisasi, migrasi, pengaturan, field form |
| 4 | [Frontend](frontend.md) | slot, layar, tab, kolom tabel, penggantian komponen, form |
| 5 | [Data dan gaya](data-dan-gaya.md) | hook data, panggilan API, komponen, terjemahan, tema |
| 6 | [Uji dan paket](uji-dan-paket.md) | pengujian, build, doctor, pack, dan keamanan |
| 7 | [Referensi](referensi.md) | manifest, command, metode, izin, event, hook, dan daftar slot |
| 8 | [Kompatibilitas](kompatibilitas.md) | selisih dokumen dengan Panel beta.2, dampak untuk repositori ini |
| 9 | [Sumber](sumber.md) | URL, commit, metode, dan cara verifikasi ulang |

## Halaman upstream yang diterjemahkan

| Halaman upstream | Halaman di sini |
|---|---|
| [Extensions](https://docs.pterodactyl.io/v2/extensions) | [mengelola.md](mengelola.md) |
| [Building Extensions](https://docs.pterodactyl.io/v2/extensions/building) | [membangun.md](membangun.md) |
| [Backend](https://docs.pterodactyl.io/v2/extensions/backend) | [backend.md](backend.md) |
| [Frontend](https://docs.pterodactyl.io/v2/extensions/frontend) | [frontend.md](frontend.md) |
| [Data and Styling](https://docs.pterodactyl.io/v2/extensions/data-and-styling) | [data-dan-gaya.md](data-dan-gaya.md) |
| [Testing and Packaging](https://docs.pterodactyl.io/v2/extensions/testing-and-packaging) | [uji-dan-paket.md](uji-dan-paket.md) |
| [Extension Reference](https://docs.pterodactyl.io/v2/extensions/reference) | [referensi.md](referensi.md) |
| [Themes](https://docs.pterodactyl.io/v2/guides/customization/themes) | [data-dan-gaya.md](data-dan-gaya.md#tema) dan [kompatibilitas](kompatibilitas.md#tema) |
| [Docker Deployment](https://docs.pterodactyl.io/v2/panel/docker) | [mengelola.md](mengelola.md#variabel-lingkungan) (volume extension) |

## Status informasi

Setiap klaim di folder ini termasuk salah satu dari tiga kelompok:

| Penanda | Arti |
|---|---|
| (tanpa penanda) | dari dokumen upstream, dikutip dari mdx branch `v2` |
| **(kode)** | diperiksa di kode tag `v2.0.0-beta.2` dan ditemukan di sana, atau tidak ada di dokumen |
| ⚠ beta.2 | ada di dokumen tetapi **tidak** ditemukan di tag beta.2 |

Klaim yang belum bisa diperiksa ditulis sebagai "belum diverifikasi", dengan alasannya. Daftarnya ada di [kompatibilitas](kompatibilitas.md#yang-belum-diverifikasi).

## Hubungan dengan repositori ini

Folder ini menjelaskan extension Panel secara umum. Cara repositori ini mengelolanya dijelaskan di [docs/extensions.md](../extensions.md): `PANEL_EXTENSIONS`, `PANEL_THEME`, `extensions/extensions.lock` dengan sha256, dan `./ptero ext`.

## Lihat juga

- [Indeks dokumentasi](../README.md)
- [Verifikasi](../verification.md), termasuk pemasangan extension di Panel nyata
