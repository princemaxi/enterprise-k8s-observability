FROM python:3.12-slim AS base

RUN useradd --uid 10001 --create-home appuser
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

USER 10001
EXPOSE 8080

# gunicorn over the Flask dev server — the dev server logs its own access
# lines to stderr in a non-JSON format that would pollute the structured
# log stream, and it isn't meant for anything resembling production load.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--access-logfile", "-", "app:app"]
