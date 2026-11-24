# LF’AZ Galería

Galería de fotos para iPhone que reúne en un solo lugar las fotos del teléfono y las guardadas en un NAS Synology mediante WebDAV.

## Objetivos

- **Fototeca**: un mosaico con las fotos del iPhone y del NAS ordenadas por fecha, como en el boceto. Al deslizar hacia las fotos, la barra de Liquid Glass cambia de forma: Inicio a la izquierda, **Días · Meses · Años** al centro y Configuración a la derecha.
- **Conexión al NAS** por HTTPS (dominio DDNS de Synology) con ruta automática: IP local en casa y Tailscale fuera de casa, validando siempre el certificado del dominio. Es la misma conexión de LF’AZ Videos.
- **Fotos del iPhone** leídas con PhotoKit. La app solo lee y nunca cambia ni borra nada.
- **Todos los formatos** que iOS puede abrir: JPG, HEIC, PNG, GIF, WebP, TIFF, AVIF y RAW (DNG, CR2, CR3, NEF, ARW, RAF, ORF…), además de videos MOV, MP4 y M4V.

## Fase 1 (0.1.0): lectura

- Fototeca con mosaico y escalas Días, Meses y Años; tocar un año abre sus meses y tocar un mes abre sus días.
- Visor a pantalla completa: deslizar entre fotos, pellizcar o doble toque para hacer zoom, deslizar hacia abajo para cerrar. Live Photos y videos del iPhone; los videos del NAS se descargan y se reproducen.
- Pestaña NAS con todas las fotos del NAS juntas, ordenadas por fecha, bajo un encabezado compacto; la carpeta, la ruta y las acciones están en el menú «…».
- Álbumes propios de la app: pueden mezclar fotos del iPhone y del NAS y viven solo en la app (no cambian la fototeca ni el NAS). Se agregan fotos desde el visor.
- Miniaturas del NAS: primero se usan las que genera Synology Photos (`@eaDir/…/SYNOPHOTO_THUMB_XL.jpg`); si no están disponibles, se descarga el original una sola vez y se guarda una miniatura en el iPhone.
- La fecha de las fotos del NAS se toma del nombre (`IMG_20230514_101530.jpg`, `WhatsApp Image 2023-05-14 at 10.15.30.jpeg`…), de carpetas como `2023/05` o `2023/Mayo`, o de la fecha de modificación.

## Configuración del NAS

En **Configuración** escribe la dirección WebDAV de la carpeta compartida de las fotos, por ejemplo `https://tu-nas.synology.me:5006/photo/`, con tu usuario y contraseña. La app recorre todas las subcarpetas y omite `@eaDir`, `#recycle` y los archivos ocultos.

## Compilación

El proyecto se genera con XcodeGen y se compila en GitHub Actions sobre macOS, sin necesidad de una Mac propia. Cada push compila, corre las pruebas e incluye un IPA sin firmar. En `main`, si están los secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` y `APPLE_TEAM_ID`, la app se firma con fastlane match (rama `certificados`) y se sube a TestFlight. Antes de la primera subida hay que crear la app con el identificador `com.lfaz.galeria.ios` en App Store Connect.
