#!/bin/zsh
set -eu
destination="${1:?Supply a new fixture directory}"
command -v say >/dev/null
command -v ffmpeg >/dev/null
if [[ -e "$destination" ]]; then
  print -u2 'Choose a new fixture directory; existing content will not be replaced.'
  exit 1
fi
mkdir -p "$destination"
say -v 'Mónica' -r 145 -o "$destination/lecture.aiff" 'Esta grabación es una prueba inventada de transcripción. Hoy explicamos cómo organizar un cuaderno de estudio. El concepto alfa utiliza tres pasos. Primero leemos el texto, después ordenamos las ideas y finalmente revisamos el resultado. Atención, corrijo la explicación anterior: el concepto alfa utiliza dos pasos, no tres. La revisión se hace al final del segundo paso. No copiéis este inciso: mañana voy a comprar manzanas. El concepto beta es importante para el examen. Significa ordenar los elementos por fecha. Conservad las negaciones, los números y las correcciones. Esta es la última frase de la grabación de prueba.'
ffmpeg -hide_banner -loglevel error -i "$destination/lecture.aiff" -ar 16000 -ac 1 "$destination/lecture.wav"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=blue:s=320x240:r=10 -i "$destination/lecture.wav" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$destination/lecture.mp4"
print "Created invented audio/video fixtures in $destination"
