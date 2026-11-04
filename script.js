// Счётчик и фильтр реализованы через updateStats() и filterGifts()
function addGift() {
  const giftInput = document.getElementById('giftInput');
  const recipientInput = document.getElementById('recipientInput');
  const giftText = giftInput.value.trim();
  const recipientText = recipientInput.value.trim();
 
  if (giftText === '') {
    alert('Введите название подарка!');
    return;
  }
 
  const giftList = document.getElementById('giftList');
  const li = document.createElement('li');
  li.innerHTML = `
    <span class="gift-name">${giftText}</span>
    <span class="recipient">для: ${recipientText || 'не указано'}</span>
    <button class="btn-bought" onclick="toggleBought(this)">Куплено</button>
    <button onclick="removeGift(this)">Удалить</button>
  `;
  giftList.appendChild(li);
 
  giftInput.value = '';
  recipientInput.value = '';
  giftInput.focus();
  updateStats();
}
 
function toggleBought(btn) {
  const li = btn.parentElement;
  li.classList.toggle('bought');
  btn.textContent = li.classList.contains('bought') ? '✓ Куплен' : 'Куплено';
  updateStats();
}
 
function removeGift(btn) {
  btn.parentElement.remove();
  updateStats();
}
 
function updateStats() {
  const items = document.querySelectorAll('#giftList li');
  const bought = document.querySelectorAll('#giftList li.bought');
  document.getElementById('totalCount').textContent = items.length;
  document.getElementById('boughtCount').textContent = bought.length;
}
 
function filterGifts(type) {
  const items = document.querySelectorAll('#giftList li');
  items.forEach(li => {
    if (type === 'all') {
      li.style.display = '';
    } else if (type === 'bought') {
      li.style.display = li.classList.contains('bought') ? '' : 'none';
    } else {
      li.style.display = li.classList.contains('bought') ? 'none' : '';
    }
  });
}
