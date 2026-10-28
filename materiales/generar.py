#!/usr/bin/env python3
"""Genera el PDF de un material NutriLogos a partir de su HTML.

Uso:   python3 generar.py plantilla-una-pagina.html [salida.pdf]
Requiere: pip install weasyprint
"""
import sys, pathlib
from weasyprint import HTML

origen = pathlib.Path(sys.argv[1]).resolve()
destino = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else origen.with_suffix('.pdf')
HTML(filename=str(origen), base_url=str(origen.parent)).write_pdf(str(destino))
print('PDF generado:', destino)
