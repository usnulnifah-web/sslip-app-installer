# SSLIP App Installer

Installer sekali-paste untuk memasang `usnulnifah-web/installweb` pada VPS Ubuntu/Debian menggunakan domain sementara berbasis `sslip.io`.

## Hasil

Jika IP publik VPS adalah `203.0.113.10`, installer akan membuat domain:

```text
203.0.113.10.sslip.io
```

Lalu memasang HTTPS melalui Let's Encrypt sehingga aplikasi dapat dibuka melalui:

```text
https://203.0.113.10.sslip.io
```

## Prasyarat

- VPS Ubuntu/Debian dengan IPv4 publik.
- Login root atau user dengan sudo.
- Port 22, 80, dan 443 terbuka.
- Repository privat dapat di-clone melalui SSH GitHub.
- Email aktif untuk notifikasi Let's Encrypt.
- VPS baru atau siap ditimpa konfigurasi Nginx aplikasi ini.

## Sekali paste

Jalankan di VPS:

```bash
rm -rf /tmp/sslip-app-installer && git clone --depth=1 git@github.com:usnulnifah-web/sslip-app-installer.git /tmp/sslip-app-installer && sudo bash /tmp/sslip-app-installer/install-sslip.sh
```

Installer otomatis:

1. Memasang Node.js 20, pnpm, Nginx, MariaDB, Certbot, dan dependency sistem.
2. Mendeteksi IPv4 publik.
3. Menggunakan `IP.sslip.io` sebagai domain sementara.
4. Membuat database lokal dan password acak.
5. Clone atau memperbarui aplikasi ScriptStore.
6. Mengisi `.env` dengan domain HTTPS dan database lokal.
7. Menjalankan migrasi, TypeScript check, dan production build.
8. Membuat service systemd agar aplikasi otomatis hidup setelah reboot.
9. Mengaktifkan Nginx reverse proxy.
10. Meminta sertifikat SSL Let's Encrypt.
11. Mengaktifkan redirect HTTP ke HTTPS.

Installer meminta satu input email. Jika instalasi sebelumnya terdeteksi, installer meminta `REINSTALL-SSL` agar tidak menimpa secara tidak sengaja.

## Informasi instalasi

Setelah berhasil, kredensial database dan URL disimpan dengan permission 600 di:

```text
/root/scriptstore-provider-install-info.txt
```

Jangan membagikan file tersebut.

## Catatan

Domain `sslip.io` hanya cocok untuk sementara, demo, testing, atau akses awal. Untuk produksi, gunakan domain sendiri. Let's Encrypt harus dapat mengakses port 80 dan 443 dari internet; sertifikat tidak dapat dibuat jika VPS berada di balik NAT tanpa port forwarding.
