FROM python:3.12-slim
WORKDIR /app
COPY . .
RUN pip install gunicorn
RUN pip install -r requirements.txt
ENV PORT=8080
CMD ["gunicorn", "--bind", ":8080", "--workers", "1", "--threads", "8", "main:app"]
